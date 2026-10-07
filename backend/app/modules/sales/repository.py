"""SQL for the sales module. Functions return records and make no business decisions."""
import uuid
from typing import Optional

import asyncpg

FREE_SEG = "(s.status = 'AVAILABLE' OR (s.status = 'LOCKED' AND s.lock_expires_at < now()))"

JOURNEY_SQL = """
    (SELECT jsonb_build_object('from_station', sa.name, 'from_code', sa.code, 'from_city', ca.code, 'departs_at', a.sched_dep,
                               'to_station', sb.name, 'to_code', sb.code, 'to_city', cb.code, 'arrives_at', z.sched_arr)
       FROM sales.ticket k
       JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
       JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id
       JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq
       JOIN net.station sb ON sb.id = z.station_id JOIN ref.city cb ON cb.id = sb.city_id
      WHERE k.booking_id = b.id LIMIT 1) AS journey"""


async def trip_on_sale_from(conn: asyncpg.Connection, trip_uid: uuid.UUID, from_seq: int) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        """SELECT t.id, t.hold_min, t.segments_count FROM ops.trip t
             JOIN ops.trip_stop a ON a.trip_id = t.id AND a.seq = $2
            WHERE t.uid = $1 AND t.status IN ('PUBLISHED','BOARDING') AND a.sales_closed_at IS NULL
              AND a.sched_dep > now() + make_interval(mins => t.sales_cutoff_min)""",
        trip_uid, from_seq)


async def seats_held_by(conn: asyncpg.Connection, user_id: int) -> int:
    return await conn.fetchval(
        "SELECT count(DISTINCT (trip_id, seat_no)) FROM ops.seat_segment WHERE lock_user_id = $1 "
        "AND status = 'LOCKED' AND lock_expires_at > now()", user_id)


async def lock_segments(conn, trip_id: int, seat_nos: list[int], from_seq: int, to_seq: int, token: uuid.UUID,
                        user_id: int, minutes: int) -> list[asyncpg.Record]:
    # Rows are locked in one fixed order (seat, then segment) before they change, so two overlapping multi-seat
    # holds wait for each other instead of deadlocking (lock order: docs/database/STANDARDS.md).
    return await conn.fetch(
        f"""WITH wanted AS (
                SELECT seat_no, seg FROM ops.seat_segment
                 WHERE trip_id = $1 AND seat_no = ANY($2::smallint[]) AND seg >= $3 AND seg < $7
                 ORDER BY seat_no, seg FOR UPDATE)
            UPDATE ops.seat_segment s
               SET status = 'LOCKED', lock_token = $4, lock_user_id = $5,
                   lock_expires_at = now() + make_interval(mins => $6)
              FROM wanted w
             WHERE s.trip_id = $1 AND s.seat_no = w.seat_no AND s.seg = w.seg
               AND {FREE_SEG}
         RETURNING s.seat_no, s.lock_expires_at""",
        trip_id, seat_nos, from_seq, token, user_id, minutes, to_seq)


async def release_segments(conn, token: uuid.UUID, user_id: int) -> int:
    return await conn.fetchval(
        """WITH r AS (UPDATE ops.seat_segment SET status = 'AVAILABLE', lock_token = NULL, lock_user_id = NULL,
                        lock_expires_at = NULL
                      WHERE lock_token = $1 AND lock_user_id = $2 AND status = 'LOCKED' RETURNING seat_no)
           SELECT count(DISTINCT seat_no) FROM r""", token, user_id)


async def held_seats(conn, trip_id: int, token: uuid.UUID, user_id: int, from_seq: int, to_seq: int) -> set[int]:
    recs = await conn.fetch(
        """SELECT seat_no, count(*) AS segs FROM ops.seat_segment
            WHERE trip_id = $1 AND lock_token = $2 AND lock_user_id = $3 AND status = 'LOCKED'
              AND lock_expires_at > now() AND seg >= $4 AND seg < $5
            GROUP BY seat_no""", trip_id, token, user_id, from_seq, to_seq)
    return {h["seat_no"] for h in recs if h["segs"] == to_seq - from_seq}


async def pair_price(conn, trip_id: int, from_seq: int, to_seq: int) -> int:
    """Fare between two stops: an explicit pair fare if the carrier set one, otherwise the ladder difference."""
    override = await conn.fetchval(
        "SELECT price FROM ops.trip_pair_fare WHERE trip_id = $1 AND from_seq = $2 AND to_seq = $3",
        trip_id, from_seq, to_seq)
    if override is not None:
        return override
    ladder = dict(await conn.fetch(
        "SELECT seq, fare_from_origin FROM ops.trip_stop WHERE trip_id = $1 AND seq IN ($2, $3)", trip_id, from_seq, to_seq))
    return ladder[to_seq] - ladder[from_seq]


async def tickets_of(conn, booking_id: int) -> list[asyncpg.Record]:
    return await conn.fetch(
        """SELECT k.uid, k.ticket_no, k.seat_no, k.status,
                  (SELECT s ->> 'label' FROM ops.trip t, jsonb_array_elements(t.seat_map -> 'seats') s
                    WHERE t.id = k.trip_id AND (s ->> 'n')::int = k.seat_no) AS seat_label, k.fare_brand_code, k.total_amount, k.from_seq, k.to_seq,
                  p.full_name, p.first_name, p.last_name, p.nationality, p.id_type, p.id_no_last4,
                  sa.name AS from_station, sa.code AS from_code, ca.code AS from_city, a.sched_dep AS departs_at,
                  sb.name AS to_station, sb.code AS to_code, cb.code AS to_city, z.sched_arr AS arrives_at, k.rules_snapshot
             FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
             JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
             JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id
             JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq
             JOIN net.station sb ON sb.id = z.station_id JOIN ref.city cb ON cb.id = sb.city_id
            WHERE k.booking_id = $1 ORDER BY k.ticket_no""", booking_id)


async def tickets_for_cancel(conn, booking_id: int) -> list[asyncpg.Record]:
    return await conn.fetch(
        """SELECT k.id, k.total_amount, k.status, k.rules_snapshot, a.sched_dep
             FROM sales.ticket k JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
            WHERE k.booking_id = $1""", booking_id)


async def mark_cancelled(conn, booking_id: int, reason: str) -> None:
    await conn.execute("UPDATE sales.ticket SET status = 'CANCELLED' WHERE booking_id = $1", booking_id)
    await conn.execute(
        """UPDATE ops.seat_segment SET status = 'AVAILABLE', ticket_id = NULL
            WHERE ticket_id IN (SELECT id FROM sales.ticket WHERE booking_id = $1)""", booking_id)
    await conn.execute(
        "UPDATE sales.booking SET status = 'CANCELLED', cancelled_at = now(), cancel_reason = $2 WHERE id = $1",
        booking_id, reason)


async def refund_allocation_line(conn, allocation_id: int, code: str, refunded: int) -> None:
    await conn.execute(
        """UPDATE fin.price_allocation_line SET refunded_amount = LEAST(amount, $3),
               status = CASE WHEN $3 >= amount THEN 'REFUNDED' WHEN $3 > 0 THEN 'PARTIAL_REFUND' ELSE status END
            WHERE allocation_id = $1 AND code = $2""", allocation_id, code, refunded)

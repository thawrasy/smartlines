-- =====================================================================
-- 1126  Charter blocks: the travellers named on the seats taken off sale (owner's decision on the next steps of 1123,
--       October 2026)
-- =====================================================================
-- A confirmed whole-trip charter holds seats of a scheduled trip (sales.charter_seat, BLOCKED on ops.seat_segment).
-- Whoever hired them (a tourism company or a traveller) names the people who travel on them: each named seat becomes
-- a ticket of one booking of the charter (sales.booking.charter_request_id), already paid by the charter (an amount of
-- nothing), so the travellers are on the carrier's list and on the manifest the authorities receive, carry tickets
-- the driver and the station board, and are seen like any other traveller. A name taken off puts the seat back in the
-- block. The booking is not cancelled or refunded on its own: the charter is (sales.charter_release_seats cancels its
-- tickets and frees every seat), and a trip the carrier cancels cancels its charters with a full refund.

ALTER TABLE sales.booking ADD COLUMN IF NOT EXISTS charter_request_id bigint REFERENCES sales.charter_request(id);
CREATE INDEX IF NOT EXISTS booking_charter_request_id_fkx ON sales.booking (charter_request_id) WHERE charter_request_id IS NOT NULL;
COMMENT ON COLUMN sales.booking.charter_request_id IS 'The charter whose blocked seats this booking names the travellers of; paid by the charter (1126)';

ALTER TABLE sales.charter_seat ADD COLUMN IF NOT EXISTS ticket_id bigint REFERENCES sales.ticket(id);
CREATE INDEX IF NOT EXISTS charter_seat_ticket_id_fkx ON sales.charter_seat (ticket_id);
COMMENT ON COLUMN sales.charter_seat.ticket_id IS 'The ticket of the traveller named on this seat, if any (1126)';

-- a named seat: the ticket takes the blocked seat on every segment of the block
CREATE OR REPLACE FUNCTION sales.charter_seat_ticket(p_request bigint, p_seat smallint, p_ticket bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c sales.charter_seat; k sales.ticket; n int;
BEGIN
  SELECT * INTO c FROM sales.charter_seat WHERE request_id = p_request AND seat_no = p_seat FOR UPDATE;
  IF NOT FOUND OR c.released_at IS NOT NULL THEN
    RAISE EXCEPTION 'CHARTER_SEAT: seat % is not held by this charter', p_seat USING ERRCODE = 'P0001';
  END IF;
  IF c.ticket_id IS NOT NULL THEN
    RAISE EXCEPTION 'CHARTER_SEAT_NAMED: seat % already has a traveller', p_seat USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO k FROM sales.ticket WHERE id = p_ticket;
  IF NOT FOUND OR k.trip_id <> c.trip_id OR k.seat_no IS DISTINCT FROM p_seat OR k.from_seq <> c.from_seq OR k.to_seq <> c.to_seq
     OR NOT EXISTS (SELECT 1 FROM sales.booking b WHERE b.id = k.booking_id AND b.charter_request_id = p_request) THEN
    RAISE EXCEPTION 'CHARTER_SEAT: the ticket does not match the seat of the charter' USING ERRCODE = 'P0001';
  END IF;
  UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = p_ticket
   WHERE trip_id = c.trip_id AND seat_no = p_seat AND seg >= c.from_seq AND seg < c.to_seq AND status = 'BLOCKED';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> c.to_seq - c.from_seq THEN
    RAISE EXCEPTION 'CHARTER_SEAT: seat % is no longer blocked on every segment', p_seat USING ERRCODE = 'P0001';
  END IF;
  UPDATE sales.charter_seat SET ticket_id = p_ticket WHERE request_id = p_request AND seat_no = p_seat;
END $$;
REVOKE ALL ON FUNCTION sales.charter_seat_ticket(bigint, smallint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.charter_seat_ticket(bigint, smallint, bigint) TO masslak_app;
COMMENT ON FUNCTION sales.charter_seat_ticket IS 'Puts a named traveller''s ticket on a seat a charter holds: the seat goes from BLOCKED to SOLD (1126)';

-- a name taken off: the ticket is cancelled and the seat goes back into the block
CREATE OR REPLACE FUNCTION sales.charter_seat_unticket(p_request bigint, p_ticket bigint) RETURNS smallint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE c sales.charter_seat; v_status text;
BEGIN
  SELECT * INTO c FROM sales.charter_seat WHERE request_id = p_request AND ticket_id = p_ticket AND released_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CHARTER_TICKET: the ticket is not on a seat of this charter' USING ERRCODE = 'P0001';
  END IF;
  SELECT status INTO v_status FROM sales.ticket WHERE id = p_ticket FOR UPDATE;
  IF v_status <> 'ISSUED' THEN
    RAISE EXCEPTION 'CHARTER_TICKET_USED: the traveller has boarded or the ticket is closed (%)', v_status USING ERRCODE = 'P0001';
  END IF;
  UPDATE sales.ticket SET status = 'CANCELLED' WHERE id = p_ticket;
  UPDATE ops.seat_segment SET status = 'BLOCKED', ticket_id = NULL
   WHERE trip_id = c.trip_id AND seat_no = c.seat_no AND seg >= c.from_seq AND seg < c.to_seq AND ticket_id = p_ticket;
  UPDATE sales.charter_seat SET ticket_id = NULL WHERE request_id = p_request AND seat_no = c.seat_no;
  RETURN c.seat_no;
END $$;
REVOKE ALL ON FUNCTION sales.charter_seat_unticket(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.charter_seat_unticket(bigint, bigint) TO masslak_app;
COMMENT ON FUNCTION sales.charter_seat_unticket IS 'Takes a traveller off a charter seat: the ticket is cancelled and the seat is blocked again (1126)';

-- a charter released: its travellers' tickets are cancelled with it, and every seat it held goes back on sale
CREATE OR REPLACE FUNCTION sales.charter_release_seats(p_request bigint) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE sales.ticket k SET status = 'CANCELLED'
    FROM sales.charter_seat c
   WHERE c.request_id = p_request AND c.released_at IS NULL AND k.id = c.ticket_id AND k.status = 'ISSUED';
  UPDATE ops.seat_segment s SET status = 'AVAILABLE', ticket_id = NULL
    FROM sales.charter_seat c
   WHERE c.request_id = p_request AND c.released_at IS NULL AND s.trip_id = c.trip_id AND s.seat_no = c.seat_no
     AND s.seg >= c.from_seq AND s.seg < c.to_seq
     AND (s.status = 'BLOCKED' OR (s.status = 'SOLD' AND s.ticket_id = c.ticket_id));
  UPDATE sales.booking SET status = 'CANCELLED', cancelled_at = now(), cancel_reason = 'CHARTER_CANCELLED'
   WHERE charter_request_id = p_request AND status = 'CONFIRMED';
  UPDATE sales.charter_seat SET released_at = now() WHERE request_id = p_request AND released_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION sales.charter_release_seats(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales.charter_release_seats(bigint) TO masslak_app;
COMMENT ON FUNCTION sales.charter_release_seats IS 'Puts back on sale the seats a cancelled whole-trip charter held, cancelling the tickets of the travellers named on them (1123, 1126)';

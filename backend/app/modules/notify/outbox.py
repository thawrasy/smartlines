"""Writing events. Call emit() inside the business transaction, so the event exists if and only if the change does."""
import json
from typing import Optional

import asyncpg

from ... import logs


async def emit(conn: asyncpg.Connection, event_type: str, aggregate_type: str, aggregate_id: int, payload: dict,
               company_id: Optional[int] = None) -> None:
    # the trace of the request that wrote it travels with the event (worker logs, webhook envelopes; app/logs.py)
    await conn.execute(
        """INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload, correlation_id)
           VALUES ($1, $2, $3, $4, $5::jsonb, $6)""",
        event_type, aggregate_type, aggregate_id, company_id, json.dumps(payload, default=str), logs.correlation())

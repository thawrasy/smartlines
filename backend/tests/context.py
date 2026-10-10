"""The API's way of setting a request context (1080): tests that act as its database login sign the context too."""
import time

from app.security import context_ticket

SET_CONTEXT = "SELECT sys.set_context($1, $2, $3, NULL, NULL, NULL, NULL, NULL, $4, $5)"


def context_args(user_id, company_id, scope: str) -> tuple:
    issued = int(time.time())
    return user_id, company_id, scope, issued, context_ticket((user_id, company_id, scope, None, None, None, None), issued)

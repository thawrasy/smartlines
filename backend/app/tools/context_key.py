"""Prints the key the database checks request contexts with (sys.context_key), in hex, for the deployment.

    python -m app.tools.context_key        # reads MASSLAK_SIGNING_SECRET like the API

deploy/migrate.sh passes it to db/create_login_roles.sql (-v context_key=...) on every start, so the database always
holds the key of the signing secret the API runs with. It is printed, never logged; keep it out of shell history.
"""
from ..security import context_key

if __name__ == "__main__":
    print(context_key().hex())

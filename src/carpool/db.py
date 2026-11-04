# this is where the place ot open a database connecton and every script and test uses connect()

import os # lets python read env variables
import psycopg # postgres driver

def connect() -> psycopg.Connection:
    """open a connection to the database named in DATABASE_URL"""
    url = os.environ.get("DATABASE_URL") # None if the varaible isn't set

    # clear message of failure instead of unnamed psycopg error
    if not url:
        raise RuntimeError(
            "DATABASE_URL is not set, Run with: uv run --env-file .env ..."
        )
    return psycopg.connect(url) #opens and returns the connection
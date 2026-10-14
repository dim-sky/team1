import os
from dotenv import load_dotenv
from databricks import sql as dbsql

load_dotenv()

QUERY_TIMEOUT_S = 30
MAX_ROWS = 1000


def get_connection():
    return dbsql.connect(
        server_hostname=os.getenv("DATABRICKS_HOST"),
        http_path=os.getenv("DATABRICKS_HTTP_PATH"),
        access_token=os.getenv("DATABRICKS_TOKEN"),
    )


if __name__ == "__main__":
    query = "SELECT COUNT(*) FROM fact_incident"  # replace with your real query

    try:
        with get_connection() as conn:
            with conn.cursor() as cursor:
                # Databricks SQL timeout, in seconds, for this session
                cursor.execute(f"SET STATEMENT_TIMEOUT = {int(QUERY_TIMEOUT_S)}")

                cursor.execute(query)
                cols = [c[0] for c in cursor.description]
                rows = cursor.fetchmany(MAX_ROWS + 1)

                truncated = len(rows) > MAX_ROWS
                rows = rows[:MAX_ROWS]

                print(cols)
                print(f"{len(rows)} rows{' (truncated)' if truncated else ''}")
    except Exception as e:
        print(f"Query failed: {e}")
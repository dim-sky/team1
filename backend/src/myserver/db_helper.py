
import os
from dotenv import load_dotenv
from databricks import sql


load_dotenv()

def get_connection():
    print("HOST:", os.getenv("DATABRICKS_HOST"))
    print("PATH:", os.getenv("DATABRICKS_HTTP_PATH"))
    print("TOKEN set:", bool(os.getenv("DATABRICKS_TOKEN")))
    return sql.connect(
        server_hostname=os.getenv("DATABRICKS_HOST"),
        http_path=os.getenv("DATABRICKS_HTTP_PATH"),
        access_token=os.getenv("DATABRICKS_TOKEN")
    )
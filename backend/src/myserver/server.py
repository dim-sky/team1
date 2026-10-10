"""Run: pip install fastapi uvicorn requests python-dotenv
        python main.py   (or: uvicorn main:app --reload)
Then open http://127.0.0.1:8000/docs
Place .env alongside this file or in a parent directory.
"""
import os
import time

import uvicorn
import requests
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from .db_helper import get_connection

load_dotenv()

CATALOG_NAME="data2026acc123456"
SCHEMA_NAME="team1"


# SELECT * FROM data2026acc123456.team1.dim_asset LIMIT 10;


app = FastAPI(title='Databricks Query API')



@app.get('/health')
def health():
    return {'status': 'ok'}


@app.get('/testq')
def test_querry():
    with get_connection() as myConnection:
        with myConnection.cursor() as cursor:
            cursor.execute("SELECT current_user()")
            print(cursor.fetchone())


            
            cursor.execute(
                f"SELECT * FROM {CATALOG_NAME}.{SCHEMA_NAME}.dim_asset LIMIT 10"
            )
            cols = [c[0] for c in cursor.description]
            print(cols)
            res = [dict(zip(cols, row)) for row in cursor.fetchall()]
            print(res)

            return res
    return 




if __name__ == '__main__':
    uvicorn.run(app, host='127.0.0.1', port=8000)



    
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
from pydantic import BaseModel
from .graph_helper import myGraph
from fastapi.middleware.cors import CORSMiddleware

load_dotenv()

CATALOG_NAME="data2026acc123456"
SCHEMA_NAME="team1"


# SELECT * FROM data2026acc123456.team1.dim_asset LIMIT 10;

class AskQuestion(BaseModel):
    role: str
    question: str




server = FastAPI(title='Databricks Query API')


server.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:4200"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)



@server.get('/health')
def health():
    return {'status': 'ok'}



@server.post("/post")
def temp(reqBody: AskQuestion):
    res = myGraph.invoke({"question": reqBody.question, "retries": 0})
    print(res)
    return {"answer": res['answer']}


@server.post("/generalMessage")
def temp(reqBody: AskQuestion):
    return {"answer": "Pending Implementation"}




    





if __name__ == '__main__':
    uvicorn.run(server, host='127.0.0.1', port=8000)



    
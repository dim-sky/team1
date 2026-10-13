"""Run: pip install fastapi uvicorn python-dotenv deepagents sqlglot
        uvicorn myserver.server:server --reload   (από τον γονικό φάκελο)
Then open http://127.0.0.1:8000/docs
Place .env alongside this file or in a parent directory.
"""
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from .graph_helper import myGraph
from .deep_agent import ask_deep_agent
from .llm_helpers import route_question, answer_general

load_dotenv()

CATALOG_NAME = "data2026acc123456"
SCHEMA_NAME = "team1"


class AskQuestion(BaseModel):
    role: str
    question: str


class AnswerResponse(BaseModel):
    answer: str
    route: str | None = None   # "graph" / "agent" / "general": χρήσιμο για debugging στο frontend


server = FastAPI(title="Databricks Query API")

server.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:4200"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@server.get("/health")
def health():
    return {"status": "ok"}


@server.post("/post", response_model=AnswerResponse)
def ask_data(reqBody: AskQuestion):
    """Ερωτήσεις δεδομένων: ο router αποφασίζει graph (1 ερώτηση) ή agent (πολλές)."""
    decision = route_question(reqBody.question)
    print(f"[/post] route={decision.route} count={decision.question_count} reason={decision.reason}")

    try:
        if decision.route == "agent":
            print("\n\nAGENT\n\n")
            answer = ask_deep_agent(reqBody.question)
        else:
            print("\n\nGRAPH\n\n")
            res = myGraph.invoke({"question": reqBody.question, "retries": 0})
            answer = res["answer"]
    except Exception as e:
        print(f"[/post] failed: {e}")
        raise HTTPException(status_code=500, detail="Η ερώτηση δεν μπόρεσε να απαντηθεί.")

    return {"answer": answer, "route": decision.route}


@server.post("/generalMessage", response_model=AnswerResponse)
def ask_general(reqBody: AskQuestion):
    """Γενικές ερωτήσεις: απλό LLM, χωρίς πρόσβαση στα δεδομένα."""
    try:
        answer = answer_general(reqBody.question)
    except Exception as e:
        print(f"[/generalMessage] failed: {e}")
        raise HTTPException(status_code=500, detail="Το μήνυμα δεν μπόρεσε να απαντηθεί.")
    return {"answer": answer, "route": "general"}


if __name__ == "__main__":
    uvicorn.run(server, host="127.0.0.1", port=8001)
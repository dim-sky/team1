"""Run: pip install fastapi uvicorn python-dotenv deepagents sqlglot "pyjwt[crypto]"
        uvicorn myserver.server:server --reload   (από τον γονικό φάκελο)
Then open http://127.0.0.1:8000/docs
Place .env alongside this file or in a parent directory.
"""
import uvicorn
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from myserver.auth import User, get_current_user
from myserver.graph_helper import myGraph
from myserver.deep_agent import ask_deep_agent
from myserver.llm_helpers import route_question, answer_general

load_dotenv()

CATALOG_NAME = "data2026acc123456"
SCHEMA_NAME = "team1"


class AskQuestion(BaseModel):
    role: str
    question: str


class AnswerResponse(BaseModel):
    answer: str
    route: str | None = None  

server = FastAPI(title="Databricks Query API")

server.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:4200",  # ng serve (development)
        "http://localhost",       # nginx in Docker
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],          # περιλαμβάνει το Authorization header
)


# Ανοιχτό: χρειάζεται για ελέγχους υγείας (π.χ. Docker), χωρίς token
@server.get("/health")
def health():
    return {"status": "ok"}


# Για να τεσταρουμε ότι λειτουργεί σωστά το JWT auth
@server.get("/me")
def me(user: User = Depends(get_current_user)):
    return {
        "status": "ok",
        "oid": user.oid,
        "name": user.name,
        "username": user.username,
        "scopes": user.claims.get("scp"),
        "expires_at": user.claims.get("exp"),
    }



@server.post("/post", response_model=AnswerResponse)
def ask_data(reqBody: AskQuestion, user: User = Depends(get_current_user)):
    """Data questions: the router decides graph (1 question) or agent (multiple)."""
    decision = route_question(reqBody.question)
    print(
        f"[/post] user={user.username} route={decision.route} "
        f"count={decision.question_count} reason={decision.reason}"
    )

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
def ask_general(reqBody: AskQuestion, user: User = Depends(get_current_user)):
    """General questions: plain LLM, without access to the data."""
    print(f"[/generalMessage] user={user.username}")
    try:
        answer = answer_general(reqBody.question)
    except Exception as e:
        print(f"[/generalMessage] failed: {e}")
        raise HTTPException(status_code=500, detail="The message could not be answered.")
    return {"answer": answer, "route": "general"}


if __name__ == "__main__":
    uvicorn.run(server, host="127.0.0.1", port=8001)
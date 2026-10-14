"""
Απλές κλήσεις LLM που δεν χρειάζονται graph ή agent:
  - route_question: αποφασίζει αν ένα μήνυμα πάει στο graph ή στον deep agent
  - answer_general: απαντά σε γενικές ερωτήσεις (χωρίς πρόσβαση στα δεδομένα)
"""
import os
from typing import Literal

from dotenv import load_dotenv
from pydantic import BaseModel, Field
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_openai import AzureChatOpenAI

load_dotenv()

llm = AzureChatOpenAI(
    azure_endpoint=os.getenv("AZURE_OPENAI_ENDPOINT"),
    azure_deployment=os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME"),
    api_version=os.getenv("OPENAI_API_VERSION"),
    temperature=0,
    max_tokens=1000,
)


# --- Router ---------------------------------------------------------------------
class RouteDecision(BaseModel):
    route: Literal["graph", "agent"] = Field(
        description="graph = one question or irrelevant message, agent = two or more data questions"
    )
    question_count: int = Field(description="How many separate data questions it contains")
    reason: str


ROUTER_PROMPT = """You are a router. You read a user's message to a system
that answers questions about incident data (counts, SLA, MTTA/MTTR, backlog,
services, teams, severity, etc.).

Count how many SEPARATE data questions the message contains, i.e. how many
different queries would need to run on the database.

route = "agent" when:
- there are 2 or more separate data questions
  e.g. "How many incidents did we have in May and which team has the worst MTTR?"
- the question is a single one but requires multi-step analysis
  e.g. "Why did SLA compliance drop in June?"

route = "graph" when:
- there is ONE data question, even if it has many filters or group bys
  e.g. "How many P1 incidents per team and per month in 2026?" (one query)
- the message is irrelevant to the data or a request to modify data
  (the graph knows how to reject it)

A question with "and" is NOT necessarily two questions: "MTTA and MTTR per
service" is one query. There are two questions when different queries are
needed (different period, different topic, different grouping).
"""

router_llm = llm.with_structured_output(RouteDecision)


def route_question(question: str) -> RouteDecision:
    """Decides where the message goes. On error, falls back to the graph."""
    try:
        return router_llm.invoke([
            SystemMessage(content=ROUTER_PROMPT),
            HumanMessage(content=question),
        ])
    except Exception as e:
        print(f"[router] failed, falling back to graph: {e}")
        return RouteDecision(route="graph", question_count=1, reason="router error")


# --- General chat ---------------------------------------------------------------
GENERAL_PROMPT = """You are a friendly and concise assistant.
You answer general questions in the user's language (Greek or English).

- You do NOT have access to company data (incidents, SLA, teams, etc.).
  If you are asked something like that, do not make up numbers: say that for questions
  about the data they should use the data chat.
- You do not have access to real-time information (weather, news, prices).
  If you are asked, say so and do not guess.
- Keep answers short, unless detail is requested.
"""


def answer_general(question: str) -> str:
    msg = llm.invoke([
        SystemMessage(content=GENERAL_PROMPT),
        HumanMessage(content=question),
    ])
    return msg.content
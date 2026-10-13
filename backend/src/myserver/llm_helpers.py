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
        description="graph = μία ερώτηση ή άσχετο μήνυμα, agent = δύο ή περισσότερες ερωτήσεις δεδομένων"
    )
    question_count: int = Field(description="Πόσες ξεχωριστές ερωτήσεις δεδομένων περιέχει")
    reason: str


ROUTER_PROMPT = """Είσαι router. Διαβάζεις το μήνυμα ενός χρήστη προς ένα σύστημα
που απαντά ερωτήσεις πάνω σε δεδομένα incidents (πλήθη, SLA, MTTA/MTTR, backlog,
υπηρεσίες, ομάδες, severity κ.λπ.).

Μέτρα πόσες ΞΕΧΩΡΙΣΤΕΣ ερωτήσεις δεδομένων περιέχει το μήνυμα, δηλαδή πόσα
διαφορετικά ερωτήματα στη βάση θα χρειαζόταν να τρέξουν.

route = "agent" όταν:
- υπάρχουν 2 ή περισσότερες ξεχωριστές ερωτήσεις δεδομένων
  π.χ. "Πόσα incidents είχαμε τον Μάιο και ποια ομάδα έχει το χειρότερο MTTR;"
- η ερώτηση είναι μία αλλά ζητά ανάλυση σε πολλά βήματα
  π.χ. "Γιατί έπεσε το SLA compliance τον Ιούνιο;"

route = "graph" όταν:
- υπάρχει ΜΙΑ ερώτηση δεδομένων, ακόμη κι αν έχει πολλά φίλτρα ή group by
  π.χ. "Πόσα P1 incidents ανά ομάδα και ανά μήνα το 2026;" (ένα ερώτημα)
- το μήνυμα είναι άσχετο με τα δεδομένα ή αίτημα τροποποίησης δεδομένων
  (το graph ξέρει να το απορρίψει)

Μια ερώτηση με "και" ΔΕΝ είναι απαραίτητα δύο ερωτήσεις: "MTTA και MTTR ανά
υπηρεσία" είναι ένα ερώτημα. Δύο ερωτήσεις είναι όταν χρειάζονται διαφορετικά
ερωτήματα (διαφορετική περίοδος, διαφορετικό θέμα, διαφορετική ομαδοποίηση).
"""

router_llm = llm.with_structured_output(RouteDecision)


def route_question(question: str) -> RouteDecision:
    """Αποφασίζει πού πάει το μήνυμα. Σε σφάλμα, πέφτει στο graph."""
    try:
        return router_llm.invoke([
            SystemMessage(content=ROUTER_PROMPT),
            HumanMessage(content=question),
        ])
    except Exception as e:
        print(f"[router] failed, falling back to graph: {e}")
        return RouteDecision(route="graph", question_count=1, reason="router error")


# --- General chat ---------------------------------------------------------------
GENERAL_PROMPT = """Είσαι φιλικός και σύντομος βοηθός.
Απαντάς σε γενικές ερωτήσεις στη γλώσσα του χρήστη (Ελληνικά ή Αγγλικά).

- ΔΕΝ έχεις πρόσβαση σε δεδομένα της εταιρείας (incidents, SLA, ομάδες κ.λπ.).
  Αν σε ρωτήσουν κάτι τέτοιο, μην επινοήσεις νούμερα: πες ότι για ερωτήσεις
  πάνω στα δεδομένα πρέπει να χρησιμοποιήσουν το chat δεδομένων.
- Δεν έχεις πρόσβαση σε real-time πληροφορίες (καιρός, ειδήσεις, τιμές).
  Αν σε ρωτήσουν, πες το και μην μαντέψεις.
- Κράτα τις απαντήσεις σύντομες, εκτός αν ζητηθεί λεπτομέρεια.
"""


def answer_general(question: str) -> str:
    msg = llm.invoke([
        SystemMessage(content=GENERAL_PROMPT),
        HumanMessage(content=question),
    ])
    return msg.content
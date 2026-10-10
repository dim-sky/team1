
import os 
from pathlib import Path
from dotenv import load_dotenv
from pydantic import BaseModel
from typing_extensions import TypedDict
from langchain_openai import AzureChatOpenAI
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langgraph.graph import StateGraph, START, END


MANAGERS_MESSAGE = "What is the weather in Arta?"

TABLE_DESCRIPTIONS_PATH = Path(__file__).parent / "gold_table_descriptions_for_llm.md"
TABLE_DESCRIPTIONS = TABLE_DESCRIPTIONS_PATH.read_text(encoding="utf-8")

SYSTEM_PROMPT = f"""Είσαι ελεγκτής διαθεσιμότητας δεδομένων.

Η ερώτηση θεωρείται ότι "μπορεί να απαντηθεί" ΜΟΝΟ αν η απάντηση μπορεί να
προκύψει από τα δεδομένα των πινάκων που περιγράφονται παρακάτω.

Κανόνες:
- Οι γενικές σου γνώσεις ΔΕΝ μετράνε. Ακόμη κι αν ξέρεις την απάντηση,
  αν δεν προκύπτει από τους πίνακες, η απάντηση είναι όχι.
- Μην υποθέτεις πίνακες ή στήλες που δεν αναφέρονται ρητά.
- Αν λείπει έστω και ένα στοιχείο που χρειάζεται η ερώτηση, η απάντηση είναι όχι.

Παραδείγματα:
- "Ποια είναι η πρωτεύουσα της Γαλλίας;" → όχι (γενική γνώση, δεν υπάρχει σε κανέναν πίνακα)
- "Πόσο είναι 2+2;" → όχι (δεν σχετίζεται με τα δεδομένα)

{TABLE_DESCRIPTIONS}
"""




load_dotenv()  


llm = AzureChatOpenAI(
    model=os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME"),
    temperature=0,
    max_tokens=1000
)


class State(TypedDict):
    question: str
    answer: str | None


class AnswerabilityDecision(BaseModel):
    can_answer: bool


structured_llm = llm.with_structured_output(AnswerabilityDecision)

def check_answerability(state: State) -> dict:
    decision = structured_llm.invoke([
        SystemMessage(content=SYSTEM_PROMPT),
        HumanMessage(content=state["question"]),
    ])
    answer = "Μπορώ να απαντήσω" if decision.can_answer else "Δεν μπορώ να απαντήσω"
    return {"answer": answer}



graph = StateGraph(State)


graph.add_node("check_answerability", check_answerability)


graph.add_edge(START, "check_answerability")
graph.add_edge("check_answerability", END)


app = graph.compile()


if __name__ == "__main__":
    result = app.invoke({"question": "Ποιες ήταν οι πωλήσεις ανά μήνα το 2025;"})
    print(result["answer"])



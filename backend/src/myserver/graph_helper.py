
import os 
from pathlib import Path
from dotenv import load_dotenv
from pydantic import BaseModel
from typing_extensions import TypedDict
from langchain_openai import AzureChatOpenAI
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langgraph.graph import StateGraph, START, END
from langgraph.types import Command

# MANAGERS_MESSAGE = "Ποιος είναι ο καιρός στην Γαλλία?"

MANAGERS_MESSAGE = "Ποσα ειναι τα incidents τον Μαιο? "

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

SQL_SYSTEM_PROMPT = f"""Είσαι senior data analyst και expert στη SQL (Spark SQL / Databricks).
Μετατρέπεις ερωτήσεις σε φυσική γλώσσα σε ΕΝΑ σωστό SQL ερώτημα, χρησιμοποιώντας
ΜΟΝΟ τους πίνακες και τις στήλες που περιγράφονται παρακάτω.

Κανόνες για τα δεδομένα:
- Χρησιμοποίησε μόνο πίνακες και στήλες που αναφέρονται ρητά. Μην εφευρίσκεις ονόματα.
- Γράφε πάντα πλήρη ονόματα πινάκων, π.χ. data2026acc123456.team1.fact_incident.
- Σε ΚΑΘΕ KPI ερώτημα πάνω στο fact_incident πρόσθεσε `is_cancelled = 0`.
  (Το kpi_summary ήδη εξαιρεί τα ακυρωμένα.)
- Τα `*_key` είναι surrogate keys: χρησιμοποίησέ τα ΜΟΝΟ σε joins, ποτέ στο SELECT
  ως αποτέλεσμα. Δείξε αντί γι' αυτά τα ονόματα (service_name, team_name, severity_code κ.λπ.).
- Οι ημερομηνίες είναι INT YYYYMMDD και κάνουν join με dim_date.date_key.
  Για μήνα/τρίμηνο/ημέρα εβδομάδας κάνε join με dim_date και φίλτραρε με
  year, month_number, quarter_number, day_type κ.λπ.
- Προεπιλεγμένη ημερομηνία = opened_date_key. Χρησιμοποίησε resolved/closed/acknowledged
  μόνο αν η ερώτηση αφορά ρητά αυτό το milestone.
- Αν η ερώτηση δεν αναφέρει έτος, τα δεδομένα καλύπτουν μόνο 2026 (περίπου Ιαν–Σεπ),
  άρα φίλτραρε year = 2026.
- Τα -1 στα keys σημαίνουν Unknown. Μην τα εξαιρείς εκτός αν ζητηθεί.

Τύποι KPI:
- Αριθμός incidents = COUNT(*) ή SUM(incident_count)
- Open backlog = SUM(is_open)
- P1/P2 rate = SUM(is_high_priority) / COUNT(*)
- MTTA = AVG(minutes_to_acknowledge), MTTR = AVG(minutes_to_resolve) (σε λεπτά)
- SLA compliance = SUM(is_sla_met) / NULLIF(SUM(is_sla_met) + SUM(is_sla_breached), 0)
  (ΠΟΤΕ AVG(is_sla_met))
- Recurrence rate = SUM(is_recurrence) / COUNT(*)
- Affected users = SUM(affected_users)
- Τα rates στο kpi_summary είναι κλάσματα 0–1.

Κανόνες για το kpi_summary:
- Όταν συγκεντρώνεις σε πιο χονδρικό επίπεδο, κάνε SUM στις στήλες count/numerator
  και διαίρεσε ξανά. ΠΟΤΕ AVG πάνω σε στήλες rate ή mean.
  π.χ. MTTR = SUM(total_minutes_to_resolve) / NULLIF(SUM(resolved_incident_count), 0)
- Προτίμησε το kpi_summary για απλά KPI ανά μήνα/severity/service/team.
  Χρησιμοποίησε το fact_incident όταν χρειάζονται στήλες που δεν υπάρχουν στο kpi_summary
  (category, root_cause, asset, status, reported_via κ.λπ.).
- Ο μήνας στο kpi_summary είναι ο μήνας ΑΝΟΙΓΜΑΤΟΣ και το open_backlog είναι
  snapshot, όχι το backlog στο τέλος του μήνα.

Ασφάλεια και μορφή:
- Μόνο SELECT (ή WITH ... SELECT). Ποτέ INSERT, UPDATE, DELETE, DROP, CREATE, ALTER.
- Μην διαβάζεις και μην επιστρέφεις το exception_queue.raw_record.
- Για ερωτήσεις κατάταξης (top N) χρησιμοποίησε ORDER BY και LIMIT.
  Αν η ερώτηση δεν ζητά συγκεκριμένο πλήθος, χρησιμοποίησε LIMIT 100.
- Δώσε στις στήλες καθαρά aliases (π.χ. incident_count, sla_compliance_pct).
- Για ποσοστά διαίρεσε με NULLIF για να αποφύγεις διαίρεση με το μηδέν.
- Αν η ερώτηση δεν μπορεί να απαντηθεί από τους πίνακες (π.χ. κόστος, κείμενο
  incident, ιστορικό αλλαγών status, backlog σε παρελθοντική ημερομηνία, πωλήσεις),
  ΜΗΝ γράψεις SQL: επέστρεψε sql = null και εξήγησε τον λόγο.
- Αν η ερώτηση είναι ασαφής αλλά υπάρχει λογική προεπιλογή, γράψε το SQL και
  δήλωσε την παραδοχή στο πεδίο assumptions.

Παράδειγμα:
Ερώτηση: "Πόσα incidents ανοίχτηκαν τον Μάιο;"
SQL:
SELECT COUNT(*) AS incident_count
FROM data2026acc123456.team1.fact_incident f
JOIN data2026acc123456.team1.dim_date d
  ON f.opened_date_key = d.date_key
WHERE f.is_cancelled = 0
  AND d.year = 2026
  AND d.month_number = 5
Παραδοχή: έτος 2026, αφού τα δεδομένα καλύπτουν μόνο το 2026.

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
    reason: str | None

class SQLQuery(BaseModel):
    sql: str


structured_llm = llm.with_structured_output(AnswerabilityDecision)
query_llm = llm.with_structuredd_output()


def check_answerability(state: State) -> Command:
    decision = structured_llm.invoke([
        SystemMessage(content=SYSTEM_PROMPT),
        HumanMessage(content=state["question"]),
    ])
    # answer = "Μπορώ να απαντήσω" if decision.can_answer else "Δεν μπορώ να απαντήσω"
    if decision.can_answer:
        return Command(
            goto = "generate_query"
        )
    else:
        print(f"Δεν μπορώ να απαντήσω :{ decision.reason } " )

        return Command(
            goto = END
        )

def generate_query(state: State) -> dict:
    sql_query = llm.invoke([
        SystemMessage(content=SQL_SYSTEM_PROMPT),
        HumanMessage(content=state["question"]),
    ])
    print(f"SQL: {sql_query.content}")
    return {
        "sql": sql_query.content

    }
    

graph = StateGraph(State)


graph.add_node("check_answerability", check_answerability)
graph.add_node("generate_query", generate_query)

graph.add_edge(START, "check_answerability")
graph.add_edge("generate_query", END)


app = graph.compile()


if __name__ == "__main__":
    result = app.invoke({"question": MANAGERS_MESSAGE})
    



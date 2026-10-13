import os
from typing import Literal
from dotenv import load_dotenv
from pydantic import BaseModel
from typing_extensions import TypedDict
from langchain_openai import AzureChatOpenAI
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.graph import StateGraph, START, END
from langgraph.types import Command

from myserver.db_helper import get_connection
from myserver.prompts import (
    SYSTEM_PROMPT,
    SQL_SYSTEM_PROMPT,
    FORMAT_RESULT,
    ERROR_PROMPT,
    FIX_SQL_PROMPT,
)

#MANAGERS_MESSAGE = "Ποιος είναι ο καιρός στην Γαλλία?"
MANAGERS_MESSAGE = "Ποσα ειναι τα incidents τον Μαιο? "
# MANAGERS_MESSAGE = "Do 24x7 teams acknowledge P1 incidents faster on weekends than teams with business-hours support?"
# MANAGERS_MESSAGE = "Delete the table incidents."

load_dotenv()

# --- Settings -----------------------------------------------------------------
MAX_RETRIES = 3          # how many times the LLM may try to fix a failing query
QUERY_TIMEOUT_S = 60     # Databricks kills any query running longer than this
MAX_ROWS = 500           # max rows fetched into memory / sent to the LLM


llm = AzureChatOpenAI(
    azure_endpoint=os.getenv("AZURE_OPENAI_ENDPOINT"),
    azure_deployment=os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME"),
    api_version=os.getenv("OPENAI_API_VERSION"),
    temperature=0,
    max_tokens=1000,
)


# --- State & structured outputs -------------------------------------------------
class State(TypedDict):
    question: str
    answer: str | None
    sql_query: str | None
    sql_query_result: str | None
    sql_error: str | None
    retries: int


class AnswerabilityDecision(BaseModel):
    can_answer: bool
    reason: str | None



class SQLQuery(BaseModel):
    sql: str


class AnswerFormat(BaseModel):
    answer_formatted: str


class IsError(BaseModel):
    is_error: bool
   

structured_llm = llm.with_structured_output(AnswerabilityDecision)
query_llm = llm.with_structured_output(SQLQuery)
formatted_result = llm.with_structured_output(AnswerFormat)
error_result = llm.with_structured_output(IsError)


# --- Nodes ----------------------------------------------------------------------
def check_answerability(state: State) -> Command[Literal["generate_query", "__end__"]]:
    decision = structured_llm.invoke([
        SystemMessage(content=SYSTEM_PROMPT),
        HumanMessage(content=state["question"]),
    ])
    if decision.can_answer:
        return Command(goto="generate_query")
    
    return Command(goto=END, update={"answer": decision.reason})


def generate_query(state: State) -> dict:

    sql_query = query_llm.invoke([
        SystemMessage(content=SQL_SYSTEM_PROMPT),
        HumanMessage(content=state["question"]),
    ])
    # return {"sql_query": "SELECT * FROM sales"}
    return {"sql_query": sql_query.sql}


def test_query(state: State) -> Command[Literal["evaluate_databricks_result"]]:
    sql = state["sql_query"].strip().rstrip(";")
    print(sql)

    try:
        with get_connection() as conn:
            with conn.cursor() as cursor:
                # Server-side timeout so a runaway query can't hang the graph
                cursor.execute(f"SET STATEMENT_TIMEOUT = {QUERY_TIMEOUT_S}")

                cursor.execute(sql)
                cols = [c[0] for c in cursor.description]
                rows = cursor.fetchmany(MAX_ROWS + 1)

        truncated = len(rows) > MAX_ROWS
        res = [dict(zip(cols, row)) for row in rows[:MAX_ROWS]]
        result_text = str(res)
        if truncated:
            result_text += f"\n(Result truncated to the first {MAX_ROWS} rows.)"

        return Command(
            goto="evaluate_databricks_result",
            update={"sql_query_result": result_text, "sql_error": None},
        )

    except Exception as e:
        print(f"[test_query] SQL failed: {e}")
        return Command(
            goto="evaluate_databricks_result",
            update={"sql_query_result": None, "sql_error": str(e)},
        )


def evaluate_databricks_result(
    state: State,
) -> Command[Literal["format_result", "test_query", "__end__"]]:
    retries = state.get("retries", 0)

    if state.get("sql_error"):
        # A database error is definitely an error, so there's no need to ask the LLM
        problem = state["sql_error"]
    else:
        # The query ran; ask the LLM whether the result actually answers the question
        verdict = error_result.invoke([
            SystemMessage(content=ERROR_PROMPT),
            HumanMessage(content=(
                f"Question:\n{state['question']}\n\n"
                f"SQL:\n{state['sql_query']}\n\n"
                f"Result:\n{state['sql_query_result']}"
            )),
        ])
        if not verdict.is_error:
            return Command(goto="format_result")
        problem = state["sql_query_result"]

    if retries >= MAX_RETRIES:
        return Command(goto=END, update={"answer": "Max agentic loops hit."})

    new_query = query_llm.invoke([
        SystemMessage(content=FIX_SQL_PROMPT),
        HumanMessage(content=(
            f"Question:\n{state['question']}\n\n"
            f"SQL:\n{state['sql_query']}\n\n"
            f"Error:\n{problem}"
        )),
    ])
    return Command(
        goto="test_query",
        update={"sql_query": new_query.sql, "retries": retries + 1},
    )


def format_result(state: State) -> dict:
    formatted = formatted_result.invoke([
        SystemMessage(content=FORMAT_RESULT),
        HumanMessage(content=(
            f"Question:\n{state['question']}\n\n"
            f"SQL:\n{state['sql_query']}\n\n"
            f"Result:\n{state['sql_query_result']}"
        )),
    ])
    return {"answer": formatted.answer_formatted}


# --- Graph ----------------------------------------------------------------------
graph = StateGraph(State)

graph.add_node("check_answerability", check_answerability)
graph.add_node("generate_query", generate_query)
graph.add_node("test_query", test_query)
graph.add_node("evaluate_databricks_result", evaluate_databricks_result)
graph.add_node("format_result", format_result)

graph.add_edge(START, "check_answerability")
graph.add_edge("generate_query", "test_query")
graph.add_edge("format_result", END)
# Other transitions are handled by the Command(goto=...) returns in each node

myGraph = graph.compile()


if __name__ == "__main__":
<<<<<<< HEAD
    pass
    result = myGraph.invoke({"question": MANAGERS_MESSAGE, "retries": 0})
    print(result.get("answer"))
=======
     pass
    #  result = myGraph.invoke({"question": MANAGERS_MESSAGE, "retries": 0})
    #  print(result.get("answer"))


     
>>>>>>> 2848945 (Update deep agent and backend)

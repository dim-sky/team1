
import os 
from pathlib import Path
from dotenv import load_dotenv
from pydantic import BaseModel
from typing_extensions import TypedDict
from langchain_openai import AzureChatOpenAI
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langgraph.graph import StateGraph, START, END
from langgraph.types import Command
from myserver.db_helper import get_connection
from myserver.prompts import SYSTEM_PROMPT, SQL_SYSTEM_PROMPT, FORMAT_RESULT, ERROR_PROMPT, FIX_SQL_PROMPT

# MANAGERS_MESSAGE = "Ποιος είναι ο καιρός στην Γαλλία?"

# MANAGERS_MESSAGE = "Ποσα ειναι τα incidents τον Μαιο? "

MANAGERS_MESSAGE = " Do 24x7 teams acknowledge P1 incidents faster on weekends than teams with business-hours support?"

load_dotenv()  

llm = AzureChatOpenAI(
    model=os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME"),
    temperature=0,
    max_tokens=1000
)


class State(TypedDict):
    question: str
    answer: str | None
    sql_query: str | None
    sql_query_result: str | None


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
    sql_query = query_llm.invoke([
        SystemMessage(content=SQL_SYSTEM_PROMPT),
        HumanMessage(content=state["question"]),
    ])
    #print(f"SQL: {sql_query.content}")
    return {
        "sql_query": sql_query.sql
    }

def test_query(state: State) -> Command:
    #print(state)
    with get_connection() as myConnection:
        with myConnection.cursor() as cursor:
            cursor.execute(
                state["sql_query"]
            )
            cols = [c[0] for c in cursor.description]
            #print(cols)
            res = [dict(zip(cols, row)) for row in cursor.fetchall()]
            print(res)   
    return Command(goto='format_result', update={"sql_query_result":res})

def evaluate_databricks_result(state: State) -> Command:
    is_error = error_result.invoke([
                SystemMessage(content=ERROR_PROMPT),
                HumanMessage(content=(
                    f"Question:\n{state['question']}\n\n"
                    f"SQL:\n{state['sql_query']}\n\n"
                    f"Result:\n{state['sql_query_result']}"
                )),
            ])
    if is_error:
        new_query = query_llm.invoke([
                SystemMessage(content=FIX_SQL_PROMPT),
                HumanMessage(content=(
                    f"Question:\n{state['question']}\n\n"
                    f"SQL:\n{state['sql_query']}\n\n"
                    f"Error:\n{state['sql_query_result']}"
                )),
            ])
        return Command(goto='test_query', update={"sql_query":new_query})
    else:
        return Command(goto='format_result', update={"sql_query_result":error_result})
    
def format_result(state: State):
    format = formatted_result.invoke([
            SystemMessage(content=FORMAT_RESULT),
            HumanMessage(content=(
                f"Question:\n{state['question']}\n\n"
                f"SQL:\n{state['sql_query']}\n\n"
                f"Result:\n{state['sql_query_result']}"
            )),
        ])
    
    print(format.answer_formatted)



graph = StateGraph(State)


graph.add_node("check_answerability", check_answerability)
graph.add_node("generate_query", generate_query)
graph.add_node("test_query", test_query)
graph.add_node("evaluate_databricks_result", evaluate_databricks_result)
graph.add_node("format_result", format_result)

graph.add_edge(START, "check_answerability")
graph.add_edge("generate_query", "test_query")
graph.add_edge("format_result", END)


app = graph.compile()


if __name__ == "__main__":
    result = app.invoke({"question": MANAGERS_MESSAGE})
    





import os 
from dotenv import load_dotenv
from pydantic import BaseModel
from langchain_openai import AzureChatOpenAI
from langgraph.graph import StateGraph, START, END


MANAGERS_MESSAGE = "What is the number of incidents for 2026"





llm = AzureChatOpenAI(
    model=os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME"),
    temperature=0,
    max_tokens=1000
)



class State(BaseModel):
    question: str
    answer: str | None




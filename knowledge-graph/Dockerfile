FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY load_graph.py ./

# Runs once: reads the gold tables from Databricks, writes them to Neo4j, exits
CMD ["python", "load_graph.py"]

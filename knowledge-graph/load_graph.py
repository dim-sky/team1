"""
Loads the Team 1 gold tables (Databricks) into a Neo4j knowledge graph.

Graph model
-----------
Nodes (identified by BUSINESS IDs, never by *_key columns, which change on
every gold refresh):

  (:Team {team_id})                 from dim_team
  (:Service {service_id})           from dim_service
  (:Severity {code})                from dim_severity
  (:ResolutionCategory {name})      from dim_resolution_category
  (:Asset {asset_id})               from dim_asset
  (:Month {year_month})             from dim_date (one node per month)
  (:Incident {incident_id})         from fact_incident
  (:MonitoringEvent {event_id})     from fact_monitoring_event
  (:MonthlyKpi {kpi_id})            from kpi_summary

Relationships:

  (Team)-[:OWNS]->(Asset)
  (Incident)-[:AFFECTS_ASSET]->(Asset)
  (Incident)-[:AFFECTS_SERVICE]->(Service)
  (Incident)-[:ASSIGNED_TO]->(Team)
  (Incident)-[:HAS_SEVERITY]->(Severity)
  (Incident)-[:RESOLVED_AS]->(ResolutionCategory)
  (Incident)-[:OPENED_IN]->(Month)
  (Incident)-[:RECURRENCE_OF]->(Incident)
  (MonitoringEvent)-[:ON_ASSET]->(Asset)
  (MonitoringEvent)-[:FOR_SERVICE]->(Service)
  (MonitoringEvent)-[:OCCURRED_IN]->(Month)
  (MonitoringEvent)-[:LINKED_TO]->(Incident)
  (MonthlyKpi)-[:FOR_MONTH]->(Month)
  (MonthlyKpi)-[:FOR_SEVERITY]->(Severity)
  (MonthlyKpi)-[:FOR_SERVICE]->(Service)
  (MonthlyKpi)-[:FOR_TEAM]->(Team)

"Unknown" dimension rows (key -1) are not loaded, so links to them are simply
left out.
"""

import os
import sys
import time
from datetime import date, datetime
from decimal import Decimal

from databricks import sql
from neo4j import GraphDatabase

SCHEMA = os.getenv("GOLD_SCHEMA", "data2026acc123456.team1")
BATCH_SIZE = 2000
RESET_GRAPH = os.getenv("RESET_GRAPH", "true").lower() == "true"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def clean(value):
    """Convert Databricks values into types the Neo4j driver accepts."""
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime, date, str, int, float, bool)) or value is None:
        return value
    return str(value)


def read_rows(cursor, query):
    """Run a query on Databricks and yield the rows in batches of dicts."""
    cursor.execute(query.format(s=SCHEMA))
    columns = [c[0] for c in cursor.description]
    while True:
        rows = cursor.fetchmany(BATCH_SIZE)
        if not rows:
            break
        yield [{col: clean(val) for col, val in zip(columns, row)} for row in rows]


def write(session, cypher, rows):
    session.run(cypher, rows=rows).consume()


def load(session, cursor, name, query, node_cypher, rel_cyphers=()):
    """Load one table: create/update the nodes, then their relationships.

    The relationships are written after the nodes of the same batch, so a batch
    is complete once it is written. Rows keep their link fields (asset_id, ...)
    for the relationship statements, but those fields are not stored on the node.
    """
    total = 0
    for batch in read_rows(cursor, query):
        write(session, node_cypher, batch)
        for cypher in rel_cyphers:
            write(session, cypher, batch)
        total += len(batch)
        print(f"  {name}: {total} rows", flush=True)
    print(f"Loaded {name}: {total} rows", flush=True)


def connect_neo4j():
    uri = os.environ["NEO4J_URI"]
    # NEO4J_AUTH is "user/password", the same variable the Neo4j container uses
    user, _, password = os.environ["NEO4J_AUTH"].partition("/")
    driver = GraphDatabase.driver(uri, auth=(user, password))
    # Neo4j takes a few seconds to start, so wait for it
    for attempt in range(1, 31):
        try:
            driver.verify_connectivity()
            return driver
        except Exception as error:  # noqa: BLE001
            print(f"Waiting for Neo4j ({attempt}/30): {error}", flush=True)
            time.sleep(5)
    sys.exit("Neo4j did not become reachable")


# ---------------------------------------------------------------------------
# Graph setup
# ---------------------------------------------------------------------------

CONSTRAINTS = [
    "CREATE CONSTRAINT team_id IF NOT EXISTS FOR (n:Team) REQUIRE n.team_id IS UNIQUE",
    "CREATE CONSTRAINT service_id IF NOT EXISTS FOR (n:Service) REQUIRE n.service_id IS UNIQUE",
    "CREATE CONSTRAINT severity_code IF NOT EXISTS FOR (n:Severity) REQUIRE n.code IS UNIQUE",
    "CREATE CONSTRAINT resolution_name IF NOT EXISTS FOR (n:ResolutionCategory) REQUIRE n.name IS UNIQUE",
    "CREATE CONSTRAINT asset_id IF NOT EXISTS FOR (n:Asset) REQUIRE n.asset_id IS UNIQUE",
    "CREATE CONSTRAINT month_id IF NOT EXISTS FOR (n:Month) REQUIRE n.year_month IS UNIQUE",
    "CREATE CONSTRAINT incident_id IF NOT EXISTS FOR (n:Incident) REQUIRE n.incident_id IS UNIQUE",
    "CREATE CONSTRAINT event_id IF NOT EXISTS FOR (n:MonitoringEvent) REQUIRE n.event_id IS UNIQUE",
    "CREATE CONSTRAINT kpi_id IF NOT EXISTS FOR (n:MonthlyKpi) REQUIRE n.kpi_id IS UNIQUE",
]


def reset_graph(session):
    """Delete everything, in chunks so large graphs don't run out of memory."""
    print("Clearing the existing graph...", flush=True)
    while True:
        deleted = session.run(
            "MATCH (n) WITH n LIMIT 10000 DETACH DELETE n RETURN count(*) AS c"
        ).single()["c"]
        if deleted == 0:
            break


# ---------------------------------------------------------------------------
# Queries (Databricks SQL) and Cypher statements
# ---------------------------------------------------------------------------

TEAMS_SQL = """
SELECT team_id, team_name, department, location, support_hours, on_call, created_date
FROM {s}.dim_team
WHERE team_key <> -1
"""
TEAMS_CYPHER = """
UNWIND $rows AS row
MERGE (t:Team {team_id: row.team_id})
SET t.name = row.team_name, t.department = row.department, t.location = row.location,
    t.support_hours = row.support_hours, t.on_call = row.on_call,
    t.created_date = row.created_date
"""

SERVICES_SQL = """
SELECT service_id, service_name
FROM {s}.dim_service
WHERE service_key <> -1
"""
SERVICES_CYPHER = """
UNWIND $rows AS row
MERGE (s:Service {service_id: row.service_id})
SET s.name = row.service_name
"""

SEVERITIES_SQL = """
SELECT severity_code, severity_name, sort_order, is_high_priority
FROM {s}.dim_severity
WHERE severity_key <> -1
"""
SEVERITIES_CYPHER = """
UNWIND $rows AS row
MERGE (v:Severity {code: row.severity_code})
SET v.name = row.severity_name, v.sort_order = row.sort_order,
    v.is_high_priority = (row.is_high_priority = 'Yes')
"""

RESOLUTIONS_SQL = """
SELECT resolution_category, resolution_group
FROM {s}.dim_resolution_category
WHERE resolution_category_key <> -1
"""
RESOLUTIONS_CYPHER = """
UNWIND $rows AS row
MERGE (r:ResolutionCategory {name: row.resolution_category})
SET r.group = row.resolution_group
"""

MONTHS_SQL = """
SELECT DISTINCT year_month, year, quarter_number, quarter_name, month_number, month_name
FROM {s}.dim_date
"""
MONTHS_CYPHER = """
UNWIND $rows AS row
MERGE (m:Month {year_month: row.year_month})
SET m.year = row.year, m.quarter_number = row.quarter_number,
    m.quarter_name = row.quarter_name, m.month_number = row.month_number,
    m.month_name = row.month_name
"""

ASSETS_SQL = """
SELECT asset_id, asset_name, asset_type, environment, site, criticality,
       criticality_sort, install_date, lifecycle_status, owner_team_id
FROM {s}.dim_asset
WHERE asset_key <> -1
"""
ASSETS_CYPHER = """
UNWIND $rows AS row
MERGE (a:Asset {asset_id: row.asset_id})
SET a.name = row.asset_name, a.type = row.asset_type, a.environment = row.environment,
    a.site = row.site, a.criticality = row.criticality,
    a.criticality_sort = row.criticality_sort, a.install_date = row.install_date,
    a.lifecycle_status = row.lifecycle_status
"""
ASSETS_RELS = [
    """
    UNWIND $rows AS row
    MATCH (a:Asset {asset_id: row.asset_id})
    MATCH (t:Team {team_id: row.owner_team_id})
    MERGE (t)-[:OWNS]->(a)
    """,
]

INCIDENTS_SQL = """
SELECT
  f.incident_id, f.status, f.category, f.root_cause, f.reported_via,
  f.related_incident_id,
  f.opened_at, f.acknowledged_at, f.resolved_at, f.closed_at, f.last_updated_at,
  f.sla_due_at, f.sla_target_hours, f.affected_users,
  f.minutes_to_acknowledge, f.minutes_to_resolve,
  f.is_open, f.is_resolved, f.is_cancelled, f.is_high_priority, f.is_recurrence,
  f.is_sla_met, f.is_sla_breached, f.is_open_sla_breached, f.sla_status,
  f.backlog_age_hours, f.backlog_age_bucket, f.has_dq_flag, f.dq_flags_text,
  d.full_date  AS opened_date,
  d.year_month AS opened_month,
  d.day_name   AS opened_day_name,
  d.day_type   AS opened_day_type,
  a.asset_id, s.service_id, t.team_id, v.severity_code, r.resolution_category
FROM {s}.fact_incident f
JOIN {s}.dim_date d                     ON f.opened_date_key = d.date_key
LEFT JOIN {s}.dim_asset a               ON f.asset_key = a.asset_key AND a.asset_key <> -1
LEFT JOIN {s}.dim_service s             ON f.service_key = s.service_key AND s.service_key <> -1
LEFT JOIN {s}.dim_team t                ON f.assigned_team_key = t.team_key AND t.team_key <> -1
LEFT JOIN {s}.dim_severity v            ON f.severity_key = v.severity_key AND v.severity_key <> -1
LEFT JOIN {s}.dim_resolution_category r ON f.resolution_category_key = r.resolution_category_key
                                       AND r.resolution_category_key <> -1
"""
INCIDENTS_CYPHER = """
UNWIND $rows AS row
MERGE (i:Incident {incident_id: row.incident_id})
SET i.status = row.status, i.category = row.category, i.root_cause = row.root_cause,
    i.reported_via = row.reported_via, i.related_incident_id = row.related_incident_id,
    i.opened_at = row.opened_at, i.acknowledged_at = row.acknowledged_at,
    i.resolved_at = row.resolved_at, i.closed_at = row.closed_at,
    i.last_updated_at = row.last_updated_at, i.sla_due_at = row.sla_due_at,
    i.sla_target_hours = row.sla_target_hours, i.affected_users = row.affected_users,
    i.minutes_to_acknowledge = row.minutes_to_acknowledge,
    i.minutes_to_resolve = row.minutes_to_resolve,
    i.is_open = row.is_open, i.is_resolved = row.is_resolved,
    i.is_cancelled = row.is_cancelled, i.is_high_priority = row.is_high_priority,
    i.is_recurrence = row.is_recurrence, i.is_sla_met = row.is_sla_met,
    i.is_sla_breached = row.is_sla_breached,
    i.is_open_sla_breached = row.is_open_sla_breached, i.sla_status = row.sla_status,
    i.backlog_age_hours = row.backlog_age_hours,
    i.backlog_age_bucket = row.backlog_age_bucket,
    i.has_dq_flag = row.has_dq_flag, i.dq_flags_text = row.dq_flags_text,
    i.opened_date = row.opened_date, i.opened_day_name = row.opened_day_name,
    i.opened_day_type = row.opened_day_type
"""
INCIDENTS_RELS = [
    """
    UNWIND $rows AS row
    MATCH (i:Incident {incident_id: row.incident_id})
    MATCH (a:Asset {asset_id: row.asset_id})
    MERGE (i)-[:AFFECTS_ASSET]->(a)
    """,
    """
    UNWIND $rows AS row
    MATCH (i:Incident {incident_id: row.incident_id})
    MATCH (s:Service {service_id: row.service_id})
    MERGE (i)-[:AFFECTS_SERVICE]->(s)
    """,
    """
    UNWIND $rows AS row
    MATCH (i:Incident {incident_id: row.incident_id})
    MATCH (t:Team {team_id: row.team_id})
    MERGE (i)-[:ASSIGNED_TO]->(t)
    """,
    """
    UNWIND $rows AS row
    MATCH (i:Incident {incident_id: row.incident_id})
    MATCH (v:Severity {code: row.severity_code})
    MERGE (i)-[:HAS_SEVERITY]->(v)
    """,
    """
    UNWIND $rows AS row
    MATCH (i:Incident {incident_id: row.incident_id})
    MATCH (r:ResolutionCategory {name: row.resolution_category})
    MERGE (i)-[:RESOLVED_AS]->(r)
    """,
    """
    UNWIND $rows AS row
    MATCH (i:Incident {incident_id: row.incident_id})
    MATCH (m:Month {year_month: row.opened_month})
    MERGE (i)-[:OPENED_IN]->(m)
    """,
]

# Runs after ALL incidents exist, because the earlier incident may be in a later batch
RECURRENCE_CYPHER = """
MATCH (i:Incident) WHERE i.related_incident_id IS NOT NULL
MATCH (earlier:Incident {incident_id: i.related_incident_id})
MERGE (i)-[:RECURRENCE_OF]->(earlier)
"""

EVENTS_SQL = """
SELECT
  e.event_id, e.event_ts, e.received_ts, e.ingestion_delay_seconds, e.is_late_arriving,
  e.event_hour, e.source_tool, e.source_host, e.source_region,
  e.metric_name, e.metric_value, e.metric_unit, e.alert_level, e.alert_threshold,
  e.is_alert, e.is_threshold_breach, e.tags_text, e.dq_flags_text,
  e.incident_link_status,
  CASE WHEN e.incident_link_status = 'Linked' THEN e.incident_id END AS linked_incident_id,
  d.full_date  AS event_date,
  d.year_month AS event_month,
  a.asset_id, s.service_id
FROM {s}.fact_monitoring_event e
JOIN {s}.dim_date d         ON e.event_date_key = d.date_key
LEFT JOIN {s}.dim_asset a   ON e.asset_key = a.asset_key AND a.asset_key <> -1
LEFT JOIN {s}.dim_service s ON e.service_key = s.service_key AND s.service_key <> -1
"""
EVENTS_CYPHER = """
UNWIND $rows AS row
MERGE (e:MonitoringEvent {event_id: row.event_id})
SET e.event_ts = row.event_ts, e.received_ts = row.received_ts,
    e.ingestion_delay_seconds = row.ingestion_delay_seconds,
    e.is_late_arriving = row.is_late_arriving, e.event_hour = row.event_hour,
    e.event_date = row.event_date,
    e.source_tool = row.source_tool, e.source_host = row.source_host,
    e.source_region = row.source_region,
    e.metric_name = row.metric_name, e.metric_value = row.metric_value,
    e.metric_unit = row.metric_unit, e.alert_level = row.alert_level,
    e.alert_threshold = row.alert_threshold, e.is_alert = row.is_alert,
    e.is_threshold_breach = row.is_threshold_breach,
    e.tags_text = row.tags_text, e.dq_flags_text = row.dq_flags_text,
    e.incident_link_status = row.incident_link_status
"""
EVENTS_RELS = [
    """
    UNWIND $rows AS row
    MATCH (e:MonitoringEvent {event_id: row.event_id})
    MATCH (a:Asset {asset_id: row.asset_id})
    MERGE (e)-[:ON_ASSET]->(a)
    """,
    """
    UNWIND $rows AS row
    MATCH (e:MonitoringEvent {event_id: row.event_id})
    MATCH (s:Service {service_id: row.service_id})
    MERGE (e)-[:FOR_SERVICE]->(s)
    """,
    """
    UNWIND $rows AS row
    MATCH (e:MonitoringEvent {event_id: row.event_id})
    MATCH (m:Month {year_month: row.event_month})
    MERGE (e)-[:OCCURRED_IN]->(m)
    """,
    """
    UNWIND $rows AS row
    MATCH (e:MonitoringEvent {event_id: row.event_id})
    MATCH (i:Incident {incident_id: row.linked_incident_id})
    MERGE (e)-[:LINKED_TO]->(i)
    """,
]

KPI_SQL = """
SELECT
  concat_ws('|', d.year_month,
            coalesce(v.severity_code, 'Unknown'),
            coalesce(s.service_id, 'Unknown'),
            coalesce(t.team_id, 'UNKNOWN')) AS kpi_id,
  d.year_month, v.severity_code, s.service_id, t.team_id,
  k.incident_count, k.open_backlog, k.p1_p2_incident_count, k.p1_p2_rate,
  k.total_minutes_to_acknowledge, k.acknowledged_incident_count,
  k.mean_time_to_acknowledge_min,
  k.total_minutes_to_resolve, k.resolved_incident_count, k.mean_time_to_resolve_min,
  k.sla_met_count, k.sla_breached_count, k.sla_compliance_rate,
  k.recurrence_count, k.recurrence_rate, k.affected_users
FROM {s}.kpi_summary k
JOIN {s}.dim_date d          ON k.month_date_key = d.date_key
LEFT JOIN {s}.dim_severity v ON k.severity_key = v.severity_key AND v.severity_key <> -1
LEFT JOIN {s}.dim_service s  ON k.service_key = s.service_key AND s.service_key <> -1
LEFT JOIN {s}.dim_team t     ON k.assigned_team_key = t.team_key AND t.team_key <> -1
"""
KPI_CYPHER = """
UNWIND $rows AS row
MERGE (k:MonthlyKpi {kpi_id: row.kpi_id})
SET k.year_month = row.year_month,
    k.incident_count = row.incident_count, k.open_backlog = row.open_backlog,
    k.p1_p2_incident_count = row.p1_p2_incident_count, k.p1_p2_rate = row.p1_p2_rate,
    k.total_minutes_to_acknowledge = row.total_minutes_to_acknowledge,
    k.acknowledged_incident_count = row.acknowledged_incident_count,
    k.mean_time_to_acknowledge_min = row.mean_time_to_acknowledge_min,
    k.total_minutes_to_resolve = row.total_minutes_to_resolve,
    k.resolved_incident_count = row.resolved_incident_count,
    k.mean_time_to_resolve_min = row.mean_time_to_resolve_min,
    k.sla_met_count = row.sla_met_count, k.sla_breached_count = row.sla_breached_count,
    k.sla_compliance_rate = row.sla_compliance_rate,
    k.recurrence_count = row.recurrence_count, k.recurrence_rate = row.recurrence_rate,
    k.affected_users = row.affected_users
"""
KPI_RELS = [
    """
    UNWIND $rows AS row
    MATCH (k:MonthlyKpi {kpi_id: row.kpi_id})
    MATCH (m:Month {year_month: row.year_month})
    MERGE (k)-[:FOR_MONTH]->(m)
    """,
    """
    UNWIND $rows AS row
    MATCH (k:MonthlyKpi {kpi_id: row.kpi_id})
    MATCH (v:Severity {code: row.severity_code})
    MERGE (k)-[:FOR_SEVERITY]->(v)
    """,
    """
    UNWIND $rows AS row
    MATCH (k:MonthlyKpi {kpi_id: row.kpi_id})
    MATCH (s:Service {service_id: row.service_id})
    MERGE (k)-[:FOR_SERVICE]->(s)
    """,
    """
    UNWIND $rows AS row
    MATCH (k:MonthlyKpi {kpi_id: row.kpi_id})
    MATCH (t:Team {team_id: row.team_id})
    MERGE (k)-[:FOR_TEAM]->(t)
    """,
]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    driver = connect_neo4j()
    print("Connected to Neo4j", flush=True)

    with sql.connect(
        server_hostname=os.environ["DATABRICKS_SERVER_HOSTNAME"],
        http_path=os.environ["DATABRICKS_HTTP_PATH"],
        access_token=os.environ["DATABRICKS_TOKEN"],
    ) as connection, connection.cursor() as cursor, driver.session() as session:
        print(f"Connected to Databricks, reading {SCHEMA}", flush=True)

        if RESET_GRAPH:
            reset_graph(session)
        for statement in CONSTRAINTS:
            session.run(statement).consume()

        # Dimensions first, because the facts link to them
        load(session, cursor, "teams", TEAMS_SQL, TEAMS_CYPHER)
        load(session, cursor, "services", SERVICES_SQL, SERVICES_CYPHER)
        load(session, cursor, "severities", SEVERITIES_SQL, SEVERITIES_CYPHER)
        load(session, cursor, "resolution categories", RESOLUTIONS_SQL, RESOLUTIONS_CYPHER)
        load(session, cursor, "months", MONTHS_SQL, MONTHS_CYPHER)
        load(session, cursor, "assets", ASSETS_SQL, ASSETS_CYPHER, ASSETS_RELS)

        # Facts
        load(session, cursor, "incidents", INCIDENTS_SQL, INCIDENTS_CYPHER, INCIDENTS_RELS)
        session.run(RECURRENCE_CYPHER).consume()
        print("Linked recurring incidents", flush=True)
        load(session, cursor, "monitoring events", EVENTS_SQL, EVENTS_CYPHER, EVENTS_RELS)
        load(session, cursor, "monthly KPIs", KPI_SQL, KPI_CYPHER, KPI_RELS)

    driver.close()
    print("Done. Open http://localhost:7474 to explore the graph.", flush=True)


if __name__ == "__main__":
    main()
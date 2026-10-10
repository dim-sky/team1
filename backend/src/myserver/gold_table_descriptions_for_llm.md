# Gold Layer Data Catalog — IT Incident Analytics (Team 1)

All tables live in `data2026acc123456.team1`.

## Domain summary

IT service management and monitoring for a large organisation. The tables describe IT incidents (opened, acknowledged, resolved, closed), the business services, assets and support teams involved, SLA performance, recurring problems, and the automated monitoring events and alerts that precede incidents. All data is a synthetic extract covering roughly January to September 2026 and is a static snapshot, not live.

## Out of scope (cannot be answered)

- Individual users or customers (only the number of affected users per incident, not who they are)
- Incident descriptions, ticket text or comments
- Status-change history: only the latest status and its milestone timestamps exist, so no "backlog at the end of March" and no reassignment history
- Cost, revenue or financial impact
- Business-hours SLA calendars (SLA is measured in calendar time)
- Staff or engineer workload and individual agent performance
- Change, problem or request tickets (incidents only)
- Vendors and contracts
- Geographic data beyond the asset site and team location
- Any date outside the loaded window
- Real-time or current-state questions
- Forecasts, and root-cause analysis beyond the `root_cause` label

## General rules

- Columns ending in `_key` are surrogate keys, used for joins only. They are re-assigned at every refresh, so never store them or compare them across refreshes. `-1` means Unknown.
- Date keys are `INT` in `YYYYMMDD` format and join to `dim_date.date_key`.
- Always exclude cancelled incidents from incident KPIs: `WHERE is_cancelled = 0`.
- Rates in `kpi_summary` are fractions from 0 to 1 (0.25 = 25%).
- Open-backlog ageing and open SLA breaches are snapshot values as of the latest `opened_at` in the data (see `refresh_info`), not the current time.

---

## data2026acc123456.team1.dim_date

**Type:** dimension
**Grain:** One row per calendar day from 2025-01-01 to 2027-12-31 (generated, not loaded from a source).

Calendar dimension used to filter and group every fact by day, week, month, quarter or year. It plays several roles: `fact_incident` has four date keys (opened, acknowledged, resolved, closed) and `fact_monitoring_event` has one (event). There is no Unknown row; a fact date key is NULL when that milestone has not happened.

**Use for:** incidents opened per month or quarter; incidents resolved per week; weekday versus weekend incident volume; monthly trend of any KPI; events per day.

**Joins:**
- `fact_incident.opened_date_key = dim_date.date_key` (default role; use this unless the question is about another milestone)
- `fact_incident.acknowledged_date_key = dim_date.date_key`
- `fact_incident.resolved_date_key = dim_date.date_key`
- `fact_incident.closed_date_key = dim_date.date_key`
- `fact_monitoring_event.event_date_key = dim_date.date_key`
- `kpi_summary.month_date_key = dim_date.date_key` (first day of the month)

| Column | Type | Description |
|---|---|---|
| date_key | INT (YYYYMMDD) | Date as an integer, e.g. 20260314. Primary key and join target of the date keys in the fact tables. |
| full_date | DATE | The calendar date, e.g. 2026-03-14. Use for date-range filters and date arithmetic. |
| year | INT | Calendar year, e.g. 2026. |
| quarter_number | INT | Calendar quarter 1–4 (Q1 = January–March). |
| quarter_name | STRING | Values: Q1, Q2, Q3, Q4. |
| month_number | INT | Month 1–12 (1 = January). Use to order month names. |
| month_name | STRING | Full month name, e.g. January, February, March. |
| month_short | STRING | Short month name, e.g. Jan, Feb, Mar. |
| year_month | STRING | Year and month, e.g. 2026-01, 2026-02. |
| iso_week | INT | Week of the year, 1–53. |
| day_of_month | INT | Day of the month, 1–31. |
| day_of_week_number | INT | 1 = Sunday … 7 = Saturday. Use to sort day_name. |
| day_name | STRING | e.g. Monday, Tuesday, Sunday. |
| day_type | STRING | Values: Weekday, Weekend. |

---

## data2026acc123456.team1.dim_severity

**Type:** dimension
**Grain:** One row per incident severity level (P1, P2, P3, P4) plus one Unknown row.

Reference list of incident severities. P1 is the most severe. Unknown (key -1) is used only when the source severity was missing or invalid and could not be derived from the SLA target.

**Use for:** incident count by severity; SLA compliance by severity; share of P1/P2 incidents; mean time to resolve per severity.

**Joins:**
- `fact_incident.severity_key = dim_severity.severity_key`
- `kpi_summary.severity_key = dim_severity.severity_key`

| Column | Type | Description |
|---|---|---|
| severity_key | INT (surrogate key) | 1 = P1, 2 = P2, 3 = P3, 4 = P4, -1 = Unknown. For joins only. |
| severity_code | STRING | Values: P1, P2, P3, P4, Unknown. |
| severity_name | STRING | Values: P1 - Critical, P2 - High, P3 - Medium, P4 - Low, Unknown. |
| is_high_priority | STRING | 'Yes' for P1 and P2, otherwise 'No' (text, not a 0/1 flag). |
| sort_order | INT | Sort helper (1–4, 99 for Unknown). Not for analysis. |

---

## data2026acc123456.team1.dim_resolution_category

**Type:** dimension
**Grain:** One row per way an incident can be resolved, plus one 'Not resolved / Unknown' row.

Describes how a resolved or closed incident was resolved (a fix, a workaround, no fault found, duplicate, and so on). `resolution_group` separates real fixes from outcomes that needed no action. Open and cancelled incidents point to key -1.

**Use for:** how incidents are resolved (fix versus workaround); share of incidents closed as duplicate, user error or no fault found; resolution mix for P1 incidents; which resolution types take longest.

**Joins:**
- `fact_incident.resolution_category_key = dim_resolution_category.resolution_category_key`

| Column | Type | Description |
|---|---|---|
| resolution_category_key | INT (surrogate key) | Primary key; -1 = Not resolved / Unknown. For joins only. |
| resolution_category | STRING | Values: Fixed, Workaround, Configuration Change, Hardware Replaced, Restarted Service, User Error, Duplicate, No Fault Found, Not resolved / Unknown. |
| resolution_group | STRING | Values: Fix applied, No action required, Not applicable. |

---

## data2026acc123456.team1.dim_service

**Type:** dimension
**Grain:** One row per business service (14 services) plus one Unknown row.

Business services affected by incidents and monitored by events, such as Corporate Email, ERP, Payments API or Identity / SSO. Shared by both fact tables.

**Use for:** incidents per business service; which service has the worst SLA compliance; open backlog by service; alerts per service; affected users by service.

**Joins:**
- `fact_incident.service_key = dim_service.service_key`
- `fact_monitoring_event.service_key = dim_service.service_key`
- `kpi_summary.service_key = dim_service.service_key`

| Column | Type | Description |
|---|---|---|
| service_key | INT (surrogate key) | Primary key; -1 = Unknown. For joins only. |
| service_id | STRING | Business ID. Values: SVC-EMAIL, SVC-ERP, SVC-CRM, SVC-VPN, SVC-WEB, SVC-PAY, SVC-SSO, SVC-FILE, SVC-DWH, SVC-HR, SVC-NET, SVC-WKS, SVC-CLOUD, SVC-SIEM. |
| service_name | STRING | Values: Corporate Email, ERP, CRM, Remote Access VPN, Public Website, Payments API, Identity / SSO, File Storage, Data Warehouse, HR Portal, Core Network, End User Devices, Cloud Hosting, Security Monitoring, Unknown. |

---

## data2026acc123456.team1.dim_team

**Type:** dimension
**Grain:** One row per support team (24 teams) plus one Unknown row.

Support and resolver teams. A team can own assets (`dim_asset.owner_team_id`) and be assigned incidents (`fact_incident.assigned_team_key`). The two can differ: about 15% of incidents are assigned to a team other than the asset's owner. Contact details are intentionally not included.

**Use for:** incidents handled per team; SLA compliance by team; open backlog per team; which department handles the most P1 incidents; average time to resolve by team.

**Joins:**
- `fact_incident.assigned_team_key = dim_team.team_key`
- `kpi_summary.assigned_team_key = dim_team.team_key`
- `dim_asset.owner_team_id = dim_team.team_id` (owner team; `dim_asset` also carries `owner_team_name`, so this join is usually not needed)

| Column | Type | Description |
|---|---|---|
| team_key | INT (surrogate key) | Primary key; -1 = Unknown. For joins only. Re-assigned at every refresh. |
| team_id | STRING | Business ID, e.g. T01, T07, T24; UNKNOWN on the Unknown row. |
| team_name | STRING | e.g. Service Desk L1, Service Desk L2, Network Operations, Server & Virtualization, Database Administration, Cloud Platform, Identity & Access, Security Operations (24 teams in total). |
| department | STRING | Values: Service Desk, Infrastructure, Security, Applications, Workplace, Unknown. |
| location | STRING | Values: Athens, Thessaloniki, Remote, Patras, Heraklion, Unknown. |
| support_hours | STRING | Values: 24x7, 08:00-20:00, 08:00-18:00, Unknown. |
| on_call | STRING | Values: Yes, No, Unknown. |
| created_date | DATE | Date the team was created. Note: NULL when the source date was invalid. |

---

## data2026acc123456.team1.dim_asset

**Type:** dimension
**Grain:** One row per IT asset (about 400 assets) plus one Unknown row.

Configuration items such as servers, firewalls, databases and laptops, with environment, site, criticality and lifecycle state. The owner team is stored on the row (ID and name). Shared by both fact tables.

**Use for:** which assets have the most incidents; incidents by asset type or site; incidents on production versus non-production assets; assets with the most monitoring alerts; incidents on Critical assets.

**Joins:**
- `fact_incident.asset_key = dim_asset.asset_key`
- `fact_monitoring_event.asset_key = dim_asset.asset_key`

| Column | Type | Description |
|---|---|---|
| asset_key | INT (surrogate key) | Primary key; -1 = Unknown. For joins only. Re-assigned at every refresh. |
| asset_id | STRING | Business ID, e.g. AST-00001, AST-00250, AST-00400. |
| asset_name | STRING | Hostname-style name, e.g. kubernetes-node-0001, virtual-machine-0002. |
| asset_type | STRING | Values: Kubernetes Node, Virtual Machine, Database Server, Identity Server, Application Server, Firewall, Mail Server, Storage Array, Load Balancer, Desktop, SIEM Collector, Log Server, ETL Server, Web Server, VPN Appliance, Router, Mail Gateway, API Gateway, Core Switch, File Server, Laptop, Directory Server, Printer. |
| environment | STRING | Values: Production, Staging, Development. |
| site | STRING | Values: Athens DC1, Athens DC2, Thessaloniki DC, Azure West Europe, Azure Germany WC. |
| criticality | STRING | Values: Critical, High, Medium, Low, Unknown. Note: source spellings such as 'crit' and 'Med.' were standardised; unrecognised values became 'Unknown'. |
| criticality_sort | INT | Sort helper: 1 = Critical, 2 = High, 3 = Medium, 4 = Low, 99 = Unknown. Not for analysis. |
| lifecycle_status | STRING | Values: Active, Retired, Maintenance. |
| install_date | DATE | Date the asset was installed. Note: NULL when the source date was empty, unparseable or outside 2000-01-01 to today. |
| owner_team_id | STRING | Business ID of the owning team, e.g. T06, T09, T11; joins to `dim_team.team_id`. Note: NULL when the source owner team did not exist; 'UNKNOWN' only on the Unknown row. |
| owner_team_name | STRING | Name of the owning team. Note: 'Unknown' when the owner team is missing or not in dim_team. |

---

## data2026acc123456.team1.fact_incident

**Type:** fact
**Grain:** One row per incident (the latest version of each incident). One row is one incident, not one status change.

Central fact table of IT incidents with lifecycle timestamps, durations, SLA results, status flags and affected users. All incident KPIs derive from it. **Always exclude cancelled incidents from KPIs (`WHERE is_cancelled = 0`).**

**Metrics:**
- Incident count = `SUM(incident_count)` or `COUNT(*)`
- Open backlog = `SUM(is_open)`
- P1/P2 rate = `SUM(is_high_priority) / COUNT(*)`
- Mean time to acknowledge (MTTA) = `AVG(minutes_to_acknowledge)`
- Mean time to resolve (MTTR) = `AVG(minutes_to_resolve)`
- SLA compliance % = `SUM(is_sla_met) / (SUM(is_sla_met) + SUM(is_sla_breached))`
- Recurrence rate = `SUM(is_recurrence) / COUNT(*)`
- Affected users = `SUM(affected_users)`

Open-incident ageing and open SLA breaches are snapshot values as of the latest `opened_at` in the data, not the current time.

**Use for:** incidents opened per month; open backlog and its age; SLA compliance by severity or team; mean time to acknowledge and resolve; share of recurrences; users affected by service.

**Joins:**
- `fact_incident.asset_key = dim_asset.asset_key`
- `fact_incident.service_key = dim_service.service_key`
- `fact_incident.assigned_team_key = dim_team.team_key`
- `fact_incident.severity_key = dim_severity.severity_key`
- `fact_incident.resolution_category_key = dim_resolution_category.resolution_category_key`
- `fact_incident.opened_date_key = dim_date.date_key` (also `acknowledged_date_key`, `resolved_date_key`, `closed_date_key`)
- `fact_incident.incident_key = fact_monitoring_event.incident_key` (links an incident to the events recorded before it; -1 on the event side means no link)

| Column | Type | Description |
|---|---|---|
| incident_key | INT (surrogate key) | Primary key. For joins only. Re-assigned at every refresh. |
| incident_id | STRING | Business ticket number, e.g. INC-000001, INC-004263. |
| opened_date_key | INT (YYYYMMDD) | Date the incident was opened; joins to dim_date.date_key. |
| acknowledged_date_key | INT (YYYYMMDD) | Date acknowledged; joins to dim_date.date_key. NULL until acknowledged (status New). |
| resolved_date_key | INT (YYYYMMDD) | Date resolved; joins to dim_date.date_key. NULL when open or cancelled. |
| closed_date_key | INT (YYYYMMDD) | Date closed; joins to dim_date.date_key. NULL unless status is Closed (Resolved incidents have no closed date). |
| asset_key | INT (surrogate key) | Foreign key to dim_asset; -1 = Unknown. For joins only. |
| service_key | INT (surrogate key) | Foreign key to dim_service; -1 when the service is unknown. For joins only. |
| assigned_team_key | INT (surrogate key) | Foreign key to dim_team (the team assigned to resolve the incident); -1 when unknown. For joins only. |
| severity_key | INT (surrogate key) | Foreign key to dim_severity (1–4 = P1–P4, -1 = Unknown). Note: -1 only when severity text and SLA target were both unusable; where severity was derived from sla_target_hours, the row is flagged in dq_flags_text. |
| resolution_category_key | INT (surrogate key) | Foreign key to dim_resolution_category; -1 for open and cancelled incidents. For joins only. |
| status | STRING | Current status. Values: New, Acknowledged, In Progress, Resolved, Closed, Cancelled. |
| category | STRING | Values: Hardware, Software, Network, Access, Performance, Security, Capacity, Configuration. |
| root_cause | STRING | Values: Disk failure, PSU failure, Memory fault, Application bug, Failed patch, Memory leak, Link down, DNS misconfiguration, Packet loss, Expired certificate, Account lockout, Permission change, CPU saturation, Slow queries, Thread pool exhaustion, Phishing, Malware detection, Brute-force attempt, Disk full, License limit, Quota exceeded, Bad deployment, Config drift, Wrong firewall rule. |
| reported_via | STRING | Channel through which the incident was reported. Values: Monitoring, Email, Phone, Portal, Chat. |
| related_incident_id | STRING | incident_id of an earlier linked incident, e.g. INC-000111. NULL if none. |
| opened_at | TIMESTAMP (UTC) | When the incident was opened. |
| acknowledged_at | TIMESTAMP (UTC) | When the incident was acknowledged. NULL until acknowledged. |
| resolved_at | TIMESTAMP (UTC) | When the incident was resolved. NULL until resolved. |
| closed_at | TIMESTAMP (UTC) | When the incident was closed. NULL unless status is Closed. |
| sla_target_hours | INT | Hours allowed to resolve under the SLA: 4 = P1, 8 = P2, 24 = P3, 72 = P4. |
| sla_due_at | TIMESTAMP (UTC) | SLA deadline = opened_at + sla_target_hours. NULL if sla_target_hours is missing. |
| affected_users | INT | Number of users affected. Note: NULL when the source value was out of range (below 1 or above 100000) or not numeric; SUM and AVG ignore NULLs. |
| incident_count | INT | Constant 1 per incident; SUM gives the number of incidents. Cancelled incidents are included, so also filter is_cancelled = 0. |
| minutes_to_acknowledge | DOUBLE | (acknowledged_at − opened_at) in minutes; NULL until acknowledged. MTTA = AVG of this column. |
| minutes_to_resolve | DOUBLE | (resolved_at − opened_at) in minutes; NULL until resolved. MTTR = AVG of this column. |
| is_open | INT (0/1 flag) | 1 when status is New, Acknowledged or In Progress. Open backlog = SUM(is_open). |
| is_resolved | INT (0/1 flag) | 1 when status is Resolved or Closed. |
| is_cancelled | INT (0/1 flag) | 1 when status is Cancelled (raised in error or withdrawn). Exclude from every KPI. |
| is_high_priority | INT (0/1 flag) | 1 when severity is P1 or P2. P1/P2 rate = SUM(is_high_priority) / COUNT(*). |
| is_recurrence | INT (0/1 flag) | 1 when related_incident_id is not NULL (linked to an earlier incident). Recurrence rate = SUM(is_recurrence) / COUNT(*). |
| is_sla_met | INT (0/1 flag) | 1 when resolved (Resolved/Closed) and resolved_at <= sla_due_at; 0 for everything else, including open incidents. Do not use AVG(is_sla_met) for compliance. |
| is_sla_breached | INT (0/1 flag) | 1 when resolved and resolved_at > sla_due_at (resolved late); 0 otherwise. SLA compliance % = SUM(is_sla_met) / (SUM(is_sla_met) + SUM(is_sla_breached)). |
| is_open_sla_breached | INT (0/1 flag) | 1 when the incident is open and the as-of time (latest opened_at in the data) is later than sla_due_at. Snapshot value; most old open incidents are breached because the data is a static extract. |
| sla_status | STRING | Single-label SLA outcome. Values: Met, Breached, Open - Within SLA, Open - Breached, Cancelled, Unknown. The 'Open -' values are evaluated as of the latest opened_at in the data. |
| backlog_age_hours | DOUBLE | Age in hours of an open incident as of the latest opened_at in the data. NULL for incidents that are not open. |
| backlog_age_bucket | STRING | Values: Not open, < 1 day, 1-3 days, 3-7 days, > 7 days. Snapshot value as of the latest opened_at in the data. |
| has_dq_flag | INT (0/1 flag) | 1 when the row carries at least one soft data-quality note in dq_flags_text. |
| dq_flags_text | STRING | Comma-separated soft data-quality notes (empty when clean), e.g. severity_derived_from_sla, affected_users_out_of_range, severity_conflicts_with_sla. |

---

## data2026acc123456.team1.fact_monitoring_event

**Type:** fact
**Grain:** One row per monitoring event (unique event_id): one measurement or alert from a monitoring tool.

Automated measurements and alerts (CPU, memory, disk, response time, error rate, packet loss) collected by monitoring tools, optionally linked to the incident they led to. About a third of events link to an incident. Values are standardised to `metric_unit` (percent or ms). Events are a stream of readings and never change after being recorded.

**Metrics:** event count = `SUM(event_count)`; alert rate = `SUM(is_alert) / COUNT(*)`.

**Use for:** alerts triggered per month; which assets or services raise the most alerts; which metric causes the most alerts; how many events arrived late; which monitoring tool produces the most events; which incidents were preceded by alerts.

**Joins:**
- `fact_monitoring_event.asset_key = dim_asset.asset_key`
- `fact_monitoring_event.service_key = dim_service.service_key`
- `fact_monitoring_event.event_date_key = dim_date.date_key`
- `fact_monitoring_event.incident_key = fact_incident.incident_key` (only when incident_key <> -1)

| Column | Type | Description |
|---|---|---|
| event_id | STRING | Business ID of the event, e.g. EVT-0000001. |
| event_date_key | INT (YYYYMMDD) | Date of the event; joins to dim_date.date_key. |
| asset_key | INT (surrogate key) | Foreign key to dim_asset; -1 = Unknown. For joins only. |
| service_key | INT (surrogate key) | Foreign key to dim_service; -1 = Unknown. For joins only. |
| incident_key | INT (surrogate key) | Foreign key to fact_incident. -1 when the event has no incident or its incident was rejected upstream; see incident_link_status. |
| incident_id | STRING | Business ID of the linked incident, e.g. INC-004263. NULL if none. |
| incident_link_status | STRING | 'No incident' when incident_id is NULL; 'Linked' when it matches a row in fact_incident; 'Incident not in Gold' when the incident was rejected upstream. |
| event_ts | TIMESTAMP (UTC) | When the event occurred. |
| received_ts | TIMESTAMP (UTC) | When the event was received by the platform. NULL if the source value was invalid. |
| ingestion_delay_seconds | DOUBLE | Seconds between event_ts and received_ts. NULL when received_ts is NULL. |
| event_hour | INT | Hour of day of event_ts, 0–23 (UTC). |
| source_tool | STRING | Values: Azure Monitor, Zabbix, Datadog, Prometheus. |
| source_host | STRING | Collector host, e.g. collector-01, collector-08. |
| source_region | STRING | Values: Athens DC1, Athens DC2, Thessaloniki DC, Azure West Europe, Azure Germany WC. |
| metric_name | STRING | Values: cpu_utilization, memory_utilization, disk_usage, response_time, error_rate, packet_loss. |
| metric_value | DOUBLE | Measured value in metric_unit. Note: percent values given as a 0–1 ratio were multiplied by 100, and seconds were converted to milliseconds. Events with missing or non-numeric values are not in this table. |
| metric_unit | STRING | Values: percent, ms. |
| alert_threshold | DOUBLE | Threshold for the alert, in metric_unit (milliseconds for response_time). |
| alert_level | STRING | Values: info, warning, critical. |
| is_alert | INT (0/1 flag) | 1 when the alert was triggered (the metric reached its threshold). Alert rate = SUM(is_alert) / COUNT(*). |
| is_threshold_breach | INT (0/1 flag) | 1 when metric_value >= alert_threshold. |
| is_late_arriving | INT (0/1 flag) | 1 when received_ts is more than 1 hour (3600 seconds) after event_ts. |
| event_count | INT | Constant 1 per event; SUM gives the number of events. |
| tags_text | STRING | Comma-separated tags, e.g. "prod, web", "customer-facing", "db, batch". |
| dq_flags_text | STRING | Comma-separated soft data-quality notes, e.g. unit_converted, late_arriving. |

---

## data2026acc123456.team1.kpi_summary

**Type:** aggregate
**Grain:** One row per opened month × severity × service × assigned team (only combinations that have incidents). Cancelled incidents are excluded.

Pre-aggregated values of the eight KPIs (incident count, open backlog, P1/P2 rate, mean time to acknowledge, mean time to resolve, SLA compliance, recurrence rate, affected users) with numerator and denominator columns. **When rolling up to a coarser level, SUM the count columns and divide again; never average the stored rate or mean columns.** Month is the month the incident was OPENED. `open_backlog` is a current snapshot of incidents opened in that month that are still open.

**Use for:** monthly trend of incident count; SLA compliance by month; mean time to resolve by service; open backlog by team; a quick KPI summary without scanning fact_incident.

**Joins:**
- `kpi_summary.month_date_key = dim_date.date_key`
- `kpi_summary.severity_key = dim_severity.severity_key`
- `kpi_summary.service_key = dim_service.service_key`
- `kpi_summary.assigned_team_key = dim_team.team_key`

| Column | Type | Description |
|---|---|---|
| month_date_key | INT (YYYYMMDD) | First day of the month the incidents were opened, e.g. 20260301; joins to dim_date.date_key. |
| severity_key | INT (surrogate key) | Foreign key to dim_severity. |
| service_key | INT (surrogate key) | Foreign key to dim_service. |
| assigned_team_key | INT (surrogate key) | Foreign key to dim_team. |
| incident_count | INT | Number of non-cancelled incidents in the row. |
| open_backlog | INT | Incidents with status New, Acknowledged or In Progress. Snapshot: incidents opened that month that are STILL open now, not the backlog at the end of that month. |
| p1_p2_incident_count | INT | Numerator of the P1/P2 rate. |
| p1_p2_rate | DOUBLE | p1_p2_incident_count / incident_count, fraction 0–1. |
| total_minutes_to_acknowledge | DOUBLE | Numerator of MTTA: sum of minutes_to_acknowledge. |
| acknowledged_incident_count | INT | Denominator of MTTA: incidents that have an acknowledge time. |
| mean_time_to_acknowledge_min | DOUBLE | MTTA in minutes = total_minutes_to_acknowledge / acknowledged_incident_count. |
| total_minutes_to_resolve | DOUBLE | Numerator of MTTR: sum of minutes_to_resolve. |
| resolved_incident_count | INT | Denominator of MTTR: incidents that have a resolve time. |
| mean_time_to_resolve_min | DOUBLE | MTTR in minutes = total_minutes_to_resolve / resolved_incident_count. |
| sla_met_count | INT | Resolved incidents that met the SLA. |
| sla_breached_count | INT | Resolved incidents that missed the SLA. |
| sla_compliance_rate | DOUBLE | sla_met_count / (sla_met_count + sla_breached_count), fraction 0–1; resolved incidents only. |
| recurrence_count | INT | Numerator of the recurrence rate: incidents linked to an earlier incident. |
| recurrence_rate | DOUBLE | recurrence_count / incident_count, fraction 0–1. |
| affected_users | INT | Sum of affected_users. The same person can be counted in several incidents. NULL when no incident in the row has a valid value. |

---

## data2026acc123456.team1.kpi_definitions

**Type:** dimension
**Grain:** One row per KPI (8 rows).

Business definition, unit and formula of each of the eight KPIs. Use it to explain what a KPI means or how it is calculated. It holds no measurements.

**Use for:** how SLA compliance is defined; what unit mean time to resolve is in; listing all available KPIs; which columns feed the recurrence rate.

**Joins:** none; standalone reference table.

| Column | Type | Description |
|---|---|---|
| unit | STRING | Unit of the KPI. Values: count, percent, minutes. |

---

## data2026acc123456.team1.refresh_info

**Type:** dimension
**Grain:** Exactly one row.

Metadata about the freshness of the Gold layer: when it was last refreshed and the time window of the data. Use it to tell the user how current the answers are. Not for business analysis.

**Use for:** when the data was last refreshed; the latest incident date in the data; how many incidents and events are loaded; how current the data behind an answer is.

**Joins:** none; standalone one-row table.

| Column | Type | Description |
|---|---|---|
| gold_refreshed_at | TIMESTAMP (UTC) | When the Gold layer was last refreshed. Use it to tell the user how current the data is. |
| latest_incident_opened_at | TIMESTAMP (UTC) | Latest opened_at in fact_incident; also the as-of time used for open-backlog ageing and open SLA breaches. |
| last_bronze_load_at | TIMESTAMP (UTC) | Latest ingestion time in the raw (Bronze) incidents table. |

---

## data2026acc123456.team1.exception_queue

**Type:** fact
**Grain:** One row per broken data-quality rule per rejected source record (one record can appear several times).

Records that failed a hard data-quality rule and were quarantined instead of being loaded into the Gold facts and dimensions. Use it for questions about data quality and about why records are missing from the analysis. **It contains one row per rule, so count distinct `record_key` and `source_table` to count records.**

**Use for:** how many records were rejected and why; which data-quality rule fails most often; which source table has the most rejected records; why a given incident is missing.

**Joins:** no join keys to the star schema. `record_key` holds the business ID (incident_id, event_id, asset_id or team_id) of the rejected record, depending on `source_table`.

| Column | Type | Description |
|---|---|---|
| source_table | STRING | Values: bronze_teams, bronze_assets, bronze_incidents, bronze_monitoring_events. |
| record_key | STRING | Business ID of the rejected record, e.g. INC-000059, EVT-0000352, AST-00016, T13. |
| rule | STRING | The rule that failed, e.g. duplicate_key, superseded_by_later_version, exact_duplicate, invalid_timestamp:opened_at, negative_duration, closed_without_resolution, unknown_asset_key, missing_opened_at, schema_violation:metric_missing, invalid_type:metric_value, missing_asset_key. |
| rule_group | STRING | Rule without its detail suffix, e.g. duplicate_key, superseded_by_later_version, invalid_timestamp, negative_duration, unknown_asset_key, schema_violation, invalid_type. |
| raw_record | STRING | The original rejected source row as JSON text. Not for analysis; may contain personal-looking fields (e.g. manager e-mail). Do not show to end users. |

---

## data2026acc123456.team1.reconciliation_summary

**Type:** aggregate
**Grain:** One row per reconciliation check (entity × check_name).

Control totals comparing Bronze, Silver and Gold, with a PASS or FAIL status. Use it to answer whether the loaded data is complete and consistent.

**Use for:** whether the Gold tables reconcile with the source; rows rejected per source; whether any checks are failing; whether the KPI summary agrees with the incident fact table.

**Joins:** none; standalone control table.

| Column | Type | Description |
|---|---|---|
| entity | STRING | Values: incidents, monitoring_events, assets, teams. |
| check_name | STRING | Values: row_count, total_affected_users, open_backlog, kpi_summary_incident_count. |
| status | STRING | Values: PASS, FAIL. |
| bronze_value | BIGINT | Value in the raw layer (row-count checks only; NULL otherwise). |
| rejected_value | BIGINT | Rows rejected to quarantine (row-count checks only). |

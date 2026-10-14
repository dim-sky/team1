--#####################################################################
-- PIPELINE OVERVIEW
--#####################################################################
-- Raw files (CSV / JSON in a Volume)
--      |  Bronze: raw copy as STRINGS + audit columns (nothing is cleaned here)
--      v
-- Bronze tables  (streaming tables, append-only, only NEW files are loaded)
--      |  Silver: standardise, convert types, validate, deduplicate
--      v
-- For each source, 3 Silver objects (materialized views, recomputed from Bronze):
--   silver_<x>_staged : ALL rows, cleaned, plus 2 verdict columns
--                         dq_reasons = HARD errors (row is rejected -> quarantine)
--                         dq_flags   = SOFT problems (row is kept but marked)
--   silver_<x>        : only rows with NO hard errors  (this feeds Gold)
--   quarantine_<x>    : rows with hard errors, one row per broken rule
--
-- Prerequisite (run once in the SQL editor): the function data2026acc123456.silver.parse_ts
-- Prerequisite (pipeline setting): spark.sql.session.timeZone = UTC
--#####################################################################


--#####################################################
-- Bronze layer
--#####################################################
-- Bronze rules: keep the data exactly as it arrived. Every column is a STRING,
-- so bad values (e.g. 'N/A' in a date column) never break the load.
-- 6 audit columns are added to every row so any record can be traced back
-- to its source file and load (lineage).

-- incidents.csv
-- STREAMING TABLE = incremental: each run only reads files it has not seen before.
CREATE OR REFRESH STREAMING TABLE data2026acc123456.team1.bronze_incidents
AS
SELECT
  *,                                               -- all original CSV columns, untouched
  _metadata.file_path source_file,                 -- audit: which file the row came from
  _metadata.file_modification_time file_modified_at, -- audit: when that file was last modified
  current_timestamp() ingested_at,                 -- audit: when this row was loaded
  'test001'  batch_id,                             -- audit: label of the load run (hard-coded for now)
  sha2(to_json(struct(*)), 256) record_hash        -- audit: fingerprint of the whole row, used to detect identical copies
FROM STREAM read_files(                            -- Auto Loader: tracks which files were already loaded
  '/Volumes/data2026acc123456/team1/raw_data',             -- folder that holds the raw files
  format => 'csv',
  pathGlobFilter => 'incidents*.csv', --reads every file thats starts with incidents and ends in .csv
  header => true,  -- first row is not data, just headers
  inferColumnTypes => false, -- keep everything as STRING
  schemaEvolutionMode => 'addNewColumns', --drift: new columns are added
  rescuedDataColumn => '_rescued_data' --drift: unexpected data is kept, not lost
);

-- assets.csv (same pattern as incidents, only the file filter differs)
CREATE OR REFRESH STREAMING TABLE data2026acc123456.team1.bronze_assets
AS
SELECT
  *,
  _metadata.file_path source_file,
  _metadata.file_modification_time file_modified_at,
  current_timestamp() ingested_at,
  'test001'  batch_id,
  sha2(to_json(struct(*)), 256) record_hash
FROM STREAM read_files(
  '/Volumes/data2026acc123456/team1/raw_data',
  format => 'csv',
  pathGlobFilter => 'assets*.csv',                 -- only files starting with 'assets'
  header => true,  -- first row is not data, just headers
  inferColumnTypes => false, -- keep everything as STRING
  schemaEvolutionMode => 'addNewColumns', --drift: new columns are added
  rescuedDataColumn => '_rescued_data' --drift: unexpected data is kept, not lost
);


-- teams.csv (same pattern)
CREATE OR REFRESH STREAMING TABLE data2026acc123456.team1.bronze_teams
AS
SELECT
  *,
  _metadata.file_path source_file,
  _metadata.file_modification_time file_modified_at,
  current_timestamp() ingested_at,
  'test001'  batch_id,
  sha2(to_json(struct(*)), 256) record_hash
FROM STREAM read_files(
  '/Volumes/data2026acc123456/team1/raw_data',
  format => 'csv',
  pathGlobFilter => 'teams*.csv',                  -- only files starting with 'teams'
  header => true,  -- first row is not data, just headers
  inferColumnTypes => false, -- keep everything as STRING
  schemaEvolutionMode => 'addNewColumns', --drift: new columns are added
  rescuedDataColumn => '_rescued_data' --drift: unexpected data is kept, not lost
);

-- monitoring_events.json
-- Note: with inferColumnTypes => false, the nested objects (source, metric, alert)
-- and the tags array are stored as JSON TEXT (strings). Silver parses them with from_json.
CREATE OR REFRESH STREAMING TABLE data2026acc123456.team1.bronze_monitoring_events
AS
SELECT
  *,
  _metadata.file_path source_file,
  _metadata.file_modification_time file_modified_at,
  current_timestamp() ingested_at,
  'test001' batch_id,
  sha2(to_json(struct(*)), 256) record_hash
FROM STREAM read_files(
  '/Volumes/data2026acc123456/team1/raw_data',
  format => 'json',
  pathGlobFilter => 'monitoring_events*.json',
  -- multiLine => true,  -- need this cause no single line is a complete object, an event might span in multiple lines
  -- (left off because the file is JSON Lines: one complete event per line. Turn it on only for pretty-printed JSON.)
  inferColumnTypes => false,                       -- everything (including nested objects) stays text
  schemaEvolutionMode => 'addNewColumns',          -- drift: new fields become new columns
  rescuedDataColumn => '_rescued_data'             -- drift: unexpected data is kept, not lost
);


--#####################################################
-- Silver layer
--#####################################################
-- Silver rules: standardise names/types/dates/codes, validate, deduplicate.
-- HARD errors  -> row goes to quarantine (not trusted).
-- SOFT problems -> row is repaired or kept, and the issue is recorded in dq_flags.
-- Silver objects are MATERIALIZED VIEWS (not streaming tables) because
-- deduplication with row_number() and joins to other Silver tables are not
-- possible on streaming tables.

-- ===================================================================
-- silver teams
-- ===================================================================
-- Step 1: staged = every row, cleaned, with the verdict columns.
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_teams_staged AS
WITH base AS (   -- base: clean and convert each column
  SELECT
    nullif(trim(team_id), '')                                  AS team_id,   -- trim spaces; empty text becomes NULL
    trim(regexp_replace(team_name, '\\s+', ' '))               AS team_name, -- trim and collapse repeated spaces
    -- a well-formed name is not blank and not all lower-case
    -- (used to decide which of two duplicate rows is the "good" one)
    (trim(team_name) = team_name AND team_name <> lower(team_name)) AS name_is_clean,
    nullif(trim(department), '')                               AS department,
    lower(nullif(trim(manager_email), ''))                     AS manager_email,  -- emails are lower-case
    nullif(trim(location), '')                                 AS location,
    nullif(trim(support_hours), '')                            AS support_hours,
    upper(trim(on_call)) = 'Y'                                 AS on_call,        -- 'Y'/'N' text -> BOOLEAN
    try_to_date(trim(created_date), 'yyyy-MM-dd')              AS created_date,   -- text -> DATE; invalid -> NULL (no failure)
    to_json(struct(*))                                         AS raw_record,     -- original row as JSON, shown in quarantine
    source_file,       -- audit columns carried through for lineage
    batch_id,
    record_hash,
    ingested_at
  FROM data2026acc123456.team1.bronze_teams
),
ranked AS (   -- ranked: number the rows that share a team_id
  SELECT *,
    row_number() OVER (PARTITION BY team_id
                       ORDER BY name_is_clean DESC, ingested_at, record_hash) AS rn
    -- rn = 1 is the row we keep: the well-formed one first, then the earliest loaded.
  FROM base
)
SELECT *,
  -- HARD errors: any entry here sends the row to quarantine.
  -- Each CASE gives a label or NULL; filter() removes the NULLs, leaving only the problems that apply.
  filter(array(
    CASE WHEN team_id IS NULL THEN 'missing_team_id' END,
    CASE WHEN rn > 1 THEN 'duplicate_key' END           -- the extra copy of a team_id
  ), x -> x IS NOT NULL) AS dq_reasons,
  -- SOFT problems: row stays in Silver, but the issue is recorded.
  filter(array(
    CASE WHEN NOT name_is_clean THEN 'team_name_malformed' END,
    CASE WHEN created_date IS NULL THEN 'invalid_created_date' END
  ), x -> x IS NOT NULL) AS dq_flags
FROM ranked;

-- Step 2: trusted teams = rows with no hard errors (empty dq_reasons list).
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_teams AS
SELECT team_id, team_name, department, manager_email, location, support_hours, on_call, created_date,
       dq_flags, source_file, batch_id, record_hash
FROM data2026acc123456.team1.silver_teams_staged
WHERE size(dq_reasons) = 0;

-- Step 3: quarantine = rejected rows. explode() makes one row per broken rule.
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.quarantine_teams AS
SELECT team_id AS record_key, 'bronze_teams' AS source_table, explode(dq_reasons) AS rule,
       raw_record, source_file AS source_file, batch_id AS batch_id, record_hash AS record_hash,
       current_timestamp() AS processed_at   -- when the row was quarantined
FROM data2026acc123456.team1.silver_teams_staged
WHERE size(dq_reasons) > 0;


-- ===================================================================
-- silver assets
-- ===================================================================
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_assets_staged AS
WITH svc AS (   -- service_name -> service_id lookup, used to recover empty service_id
  -- Some assets have an empty service_id but a valid service_name; this map lets us fill it back in.
  SELECT trim(service_name) AS service_name, max(trim(service_id)) AS service_id
  FROM data2026acc123456.team1.bronze_assets
  WHERE nullif(trim(service_id), '') IS NOT NULL
  GROUP BY trim(service_name)
),
base AS (
  SELECT
    nullif(trim(a.asset_id), '')                                  AS asset_id,
    nullif(trim(a.asset_name), '')                                AS asset_name,
    nullif(trim(a.asset_type), '')                                AS asset_type,
    coalesce(nullif(trim(a.service_id), ''), s.service_id)        AS service_id,   -- use own id, else the recovered one
    (nullif(trim(a.service_id), '') IS NULL AND s.service_id IS NOT NULL) AS service_id_recovered, -- true when we filled it in
    nullif(trim(a.service_name), '')                              AS service_name,
    nullif(trim(a.environment), '')                               AS environment,
    nullif(trim(a.site), '')                                      AS site,
    nullif(trim(a.owner_team_id), '')                             AS owner_team_id_raw,  -- validated later against silver_teams
    -- standardise criticality spelling ('crit', 'Med.' ...) to 4 clean values
    CASE lower(trim(a.criticality))
      WHEN 'critical' THEN 'Critical' WHEN 'crit' THEN 'Critical'
      WHEN 'high' THEN 'High'
      WHEN 'medium' THEN 'Medium' WHEN 'med' THEN 'Medium' WHEN 'med.' THEN 'Medium'
      WHEN 'low' THEN 'Low'
      ELSE 'Unknown' END                                          AS criticality,
    -- try both date formats; anything else ('unknown', '2021-15-01', '31/02/2021', empty) becomes NULL
    coalesce(try_to_date(trim(a.install_date), 'yyyy-MM-dd'),
             try_to_date(trim(a.install_date), 'dd/MM/yyyy'))     AS install_date_raw,
    nullif(trim(a.lifecycle_status), '')                          AS lifecycle_status,
    to_json(struct(a.*))                                          AS raw_record,
    monotonically_increasing_id()                                 AS _row_seq,  -- row position; used as tie-breaker when picking which duplicate to keep
    a.source_file,
    a.batch_id,
    a.record_hash,
    a.ingested_at
  FROM data2026acc123456.team1.bronze_assets a
  LEFT JOIN svc s ON trim(a.service_name) = s.service_name   -- attach the recovered service_id
),
ranked AS (   -- duplicate asset_ids: keep the first loaded, mark the others rn > 1
  SELECT *,
    row_number() OVER (PARTITION BY asset_id ORDER BY ingested_at, _row_seq) AS rn
  FROM base
)
SELECT r.*,
  -- final install_date: only plausible dates (2000 .. today) survive, otherwise NULL
  CASE WHEN r.install_date_raw BETWEEN DATE'2000-01-01' AND current_date() THEN r.install_date_raw END AS install_date,
  -- owner team must exist in silver_teams, otherwise NULL (asset is kept, but flagged)
  CASE WHEN t.team_id IS NOT NULL THEN r.owner_team_id_raw END AS owner_team_id,
  -- HARD errors -> quarantine
  filter(array(
    CASE WHEN r.asset_id IS NULL THEN 'missing_asset_id' END,
    CASE WHEN r.rn > 1 THEN 'duplicate_key' END
  ), x -> x IS NOT NULL) AS dq_reasons,
  -- SOFT problems -> kept, flagged
  filter(array(
    CASE WHEN r.service_id_recovered THEN 'service_id_recovered_from_name' END,
    CASE WHEN r.service_id IS NULL THEN 'missing_service_id' END,
    CASE WHEN r.criticality = 'Unknown' THEN 'criticality_unknown' END,
    CASE WHEN r.install_date_raw IS NULL
              OR r.install_date_raw NOT BETWEEN DATE'2000-01-01' AND current_date() THEN 'invalid_install_date' END,
    CASE WHEN t.team_id IS NULL THEN 'unknown_owner_team' END
  ), x -> x IS NOT NULL) AS dq_flags
FROM ranked r
LEFT JOIN data2026acc123456.team1.silver_teams t ON r.owner_team_id_raw = t.team_id;  -- referential check against trusted teams

CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_assets AS
SELECT asset_id, asset_name, asset_type, service_id, service_name, environment, site,
       owner_team_id, criticality, install_date, lifecycle_status,
       dq_flags, source_file, batch_id, record_hash
FROM data2026acc123456.team1.silver_assets_staged
WHERE size(dq_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.quarantine_assets AS
SELECT asset_id AS record_key, 'bronze_assets' AS source_table, explode(dq_reasons) AS rule,
       raw_record, source_file AS source_file, batch_id AS batch_id, record_hash AS record_hash,
       current_timestamp() AS processed_at
FROM data2026acc123456.team1.silver_assets_staged
WHERE size(dq_reasons) > 0;


-- ===================================================================
-- silver incidents
-- ===================================================================
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_incidents_staged AS
WITH base AS (   -- base: clean text columns, parse timestamps, keep the raw text for checks
  SELECT
    nullif(trim(incident_id), '')                                 AS incident_id,
    nullif(trim(asset_id), '')                                    AS asset_id,
    nullif(trim(service_id), '')                                  AS service_id,
    nullif(trim(assigned_team_id), '')                            AS assigned_team_id,
    -- standardise severity: strip punctuation/case, then map every known spelling to P1..P4
    CASE upper(regexp_replace(trim(severity), '[^A-Za-z0-9]', ''))   -- 'p1', 'P-2', '3', 'HIGH' ...
      WHEN 'P1' THEN 'P1' WHEN 'CRITICAL' THEN 'P1' WHEN '1' THEN 'P1'
      WHEN 'P2' THEN 'P2' WHEN 'HIGH'     THEN 'P2' WHEN '2' THEN 'P2'
      WHEN 'P3' THEN 'P3' WHEN 'MEDIUM'   THEN 'P3' WHEN '3' THEN 'P3'
      WHEN 'P4' THEN 'P4' WHEN 'LOW'      THEN 'P4' WHEN '4' THEN 'P4'
      ELSE 'Unknown' END                                          AS severity_from_text,   -- empty / 'P5' / unmappable -> 'Unknown'
    -- severity implied by the SLA target: in this data 4h=P1, 8h=P2, 24h=P3, 72h=P4 (one-to-one for all well-formed rows).
    -- Used only when the severity text is missing or unmappable.
    CASE try_cast(sla_target_hours AS INT)
      WHEN 4 THEN 'P1' WHEN 8 THEN 'P2' WHEN 24 THEN 'P3' WHEN 72 THEN 'P4'
      ELSE 'Unknown' END                                          AS severity_from_sla,
    nullif(trim(category), '')                                    AS category,
    nullif(trim(root_cause), '')                                  AS root_cause,
    nullif(trim(status), '')                                      AS status,
    nullif(trim(reported_via), '')                                AS reported_via,
    nullif(trim(resolution_category), '')                         AS resolution_category,
    try_cast(sla_target_hours AS INT)                             AS sla_target_hours,  -- text -> INT, bad value -> NULL
    try_cast(affected_users AS INT)                               AS affected_users_raw, -- range check happens further down
    nullif(trim(related_incident_id), '')                         AS related_incident_id,
    -- *_raw = the original text (or NULL if empty); *_p = parsed timestamp (NULL if unparseable).
    -- Comparing the two tells us "there was a value but it was invalid".
    nullif(trim(opened_at), '')                                   AS opened_raw,
    nullif(trim(acknowledged_at), '')                             AS acknowledged_raw,
    nullif(trim(resolved_at), '')                                 AS resolved_raw,
    nullif(trim(closed_at), '')                                   AS closed_raw,
    data2026acc123456.team1.parse_ts(opened_at)                          AS opened_p,
    data2026acc123456.team1.parse_ts(acknowledged_at)                    AS acknowledged_p,
    data2026acc123456.team1.parse_ts(resolved_at)                        AS resolved_p,
    data2026acc123456.team1.parse_ts(closed_at)                          AS closed_p,
    data2026acc123456.team1.parse_ts(last_updated_at)                    AS last_updated_p,
    to_json(struct(*))                                            AS raw_record,
    source_file, batch_id, record_hash, ingested_at
  FROM data2026acc123456.team1.bronze_incidents
),
valid_ts AS (   -- a timestamp must parse AND fall in a plausible window (rejects 1970 and 2027+)
  -- Window: 2020-01-01 up to the fixed cut-off 2026-12-31 23:59:59 (fixed, so results do not depend on the day the pipeline runs). Outside it the timestamp becomes NULL.
  SELECT *,
    CASE WHEN opened_p       BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN opened_p       END AS opened_at,
    CASE WHEN acknowledged_p BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN acknowledged_p END AS acknowledged_at,
    CASE WHEN resolved_p     BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN resolved_p     END AS resolved_at,
    CASE WHEN closed_p       BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN closed_p       END AS closed_at,
    CASE WHEN last_updated_p BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN last_updated_p END AS last_updated_at,
    -- final severity: the text if it can be mapped, otherwise the one implied by the SLA, otherwise 'Unknown'
    CASE WHEN severity_from_text <> 'Unknown' THEN severity_from_text
         ELSE severity_from_sla END                               AS severity
  FROM base
),
ranked AS (     -- keep the LATEST version of each incident (late-arriving corrections win)
  SELECT *,
    -- rn = 1 is the newest version of the incident; older copies get rn > 1 and are quarantined
    row_number() OVER (PARTITION BY incident_id
                       ORDER BY last_updated_at DESC NULLS LAST, ingested_at DESC, record_hash) AS rn,
    -- hash of the newest version; lets us tell an exact copy from an older, different version
    first_value(record_hash) OVER (PARTITION BY incident_id
                       ORDER BY last_updated_at DESC NULLS LAST, ingested_at DESC, record_hash) AS latest_hash
  FROM valid_ts
)
SELECT r.*,
  -- affected_users must be 1..100000, otherwise NULL (row kept, flagged below)
  CASE WHEN r.affected_users_raw BETWEEN 1 AND 100000 THEN r.affected_users_raw END AS affected_users,
  -- HARD errors -> quarantine
  filter(array(
    CASE WHEN r.incident_id IS NULL THEN 'missing_incident_id' END,
    -- older copy of an incident: 'exact_duplicate' if identical to the newest, else a superseded older version
    CASE WHEN r.rn > 1 THEN
         CASE WHEN r.record_hash = r.latest_hash THEN 'exact_duplicate'
              ELSE 'superseded_by_later_version' END END,
    CASE WHEN r.opened_raw IS NULL THEN 'missing_opened_at'
         WHEN r.opened_at IS NULL THEN 'invalid_timestamp:opened_at' END,
    -- text existed but did not parse / was out of window -> invalid timestamp
    CASE WHEN r.acknowledged_raw IS NOT NULL AND r.acknowledged_at IS NULL THEN 'invalid_timestamp:acknowledged_at' END,
    CASE WHEN r.resolved_raw     IS NOT NULL AND r.resolved_at     IS NULL THEN 'invalid_timestamp:resolved_at' END,
    CASE WHEN r.closed_raw       IS NOT NULL AND r.closed_at       IS NULL THEN 'invalid_timestamp:closed_at' END,
    -- events happening in the wrong order
    CASE WHEN r.acknowledged_at < r.opened_at
           OR r.resolved_at     < r.opened_at
           OR r.closed_at       < r.resolved_at THEN 'negative_duration' END,
    -- a Resolved/Closed incident must say how it was resolved
    CASE WHEN r.status IN ('Resolved', 'Closed') AND r.resolution_category IS NULL THEN 'closed_without_resolution' END,
    -- the asset must exist in the trusted assets table (a = silver_assets joined below)
    CASE WHEN r.asset_id IS NULL OR a.asset_id IS NULL THEN 'unknown_asset_key' END
  ), x -> x IS NOT NULL) AS dq_reasons,
  -- SOFT problems -> kept, flagged
  filter(array(
    -- severity repair trail: derived from the SLA / still unknown / text disagrees with the SLA (needs review)
    CASE WHEN r.severity_from_text = 'Unknown' AND r.severity_from_sla <> 'Unknown' THEN 'severity_derived_from_sla'
         WHEN r.severity = 'Unknown' THEN 'severity_missing_or_invalid'
         WHEN r.severity_from_sla <> 'Unknown' AND r.severity_from_text <> r.severity_from_sla THEN 'severity_conflicts_with_sla' END,
    CASE WHEN r.affected_users_raw IS NULL
              OR r.affected_users_raw NOT BETWEEN 1 AND 100000 THEN 'affected_users_out_of_range' END
  ), x -> x IS NOT NULL) AS dq_flags
FROM ranked r
LEFT JOIN data2026acc123456.team1.silver_assets a ON r.asset_id = a.asset_id;   -- referential check (silver_assets has one row per asset_id, so no row multiplication)

CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_incidents AS
SELECT incident_id, asset_id, service_id, assigned_team_id, severity, category, root_cause, status,
       reported_via, opened_at, acknowledged_at, resolved_at, closed_at, resolution_category,
       sla_target_hours, affected_users, related_incident_id, last_updated_at,
       dq_flags, source_file, batch_id, record_hash
FROM data2026acc123456.team1.silver_incidents_staged
WHERE size(dq_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.quarantine_incidents AS
SELECT incident_id AS record_key, 'bronze_incidents' AS source_table, explode(dq_reasons) AS rule,
       raw_record, source_file AS source_file, batch_id AS batch_id, record_hash AS record_hash,
       current_timestamp() AS processed_at
FROM data2026acc123456.team1.silver_incidents_staged
WHERE size(dq_reasons) > 0;


-- ===================================================================
-- silver monitoring events (flatten the JSON structs)
-- ===================================================================
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_monitoring_events_staged AS
WITH j AS (   -- j: turn the JSON text columns into real structs / arrays
  SELECT *,
    -- original Bronze row as JSON, for the quarantine table.
    -- (struct(*) here expands to the original Bronze columns only, not the parsed ones added below)
    to_json(struct(*))                                                    AS raw_record_all,
    from_json(source, 'tool STRING, host STRING, region STRING')          AS source_j,   -- values read as STRING first, converted to numbers later
    from_json(metric, 'name STRING, value STRING, unit STRING')           AS metric_j,
    from_json(alert,  'triggered STRING, threshold STRING, level STRING') AS alert_j,
    from_json(tags,   'ARRAY<STRING>')                                    AS tags_j
  FROM data2026acc123456.team1.bronze_monitoring_events
),
base AS (   -- base: flatten (struct.field -> own column) and convert types
  SELECT
    nullif(trim(event_id), '')                         AS event_id,
    nullif(trim(CAST(event_timestamp AS STRING)), '')  AS event_raw,
    data2026acc123456.team1.parse_ts(CAST(event_timestamp AS STRING)) AS event_p,     -- parsed event time
    data2026acc123456.team1.parse_ts(CAST(received_at AS STRING))     AS received_p,  -- parsed time the event reached us
    nullif(trim(asset_id), '')                         AS asset_id,
    nullif(trim(incident_id), '')                      AS incident_id,
    source_j.tool                                      AS source_tool,
    source_j.host                                      AS source_host,
    source_j.region                                    AS source_region,
    (metric_j IS NULL OR metric_j.name IS NULL)        AS metric_missing,   -- true when the whole metric object is absent
    lower(trim(metric_j.name))                         AS metric_name,
    lower(trim(metric_j.unit))                         AS unit_raw,
    -- '12,5' -> 12.5 ; '', 'n/a', 'NaN' -> NULL
    CASE WHEN isnan(try_cast(replace(trim(metric_j.value), ',', '.') AS DOUBLE)) THEN NULL
         ELSE try_cast(replace(trim(metric_j.value), ',', '.') AS DOUBLE) END AS value_raw,
    try_cast(alert_j.triggered AS BOOLEAN)             AS alert_triggered,
    try_cast(alert_j.threshold AS DOUBLE)              AS alert_threshold,
    lower(trim(alert_j.level))                         AS alert_level,
    tags_j                                             AS tags,
    raw_record_all                                     AS raw_record,
    source_file, batch_id, record_hash, ingested_at AS ingested_at
  FROM j
),
conformed AS (   -- standardise units: percent, ms
  SELECT *,
    -- ratio (0..1) -> percent; seconds -> milliseconds
    CASE WHEN unit_raw = 'ratio'                       THEN value_raw * 100
         WHEN unit_raw IN ('s', 'sec', 'seconds')      THEN value_raw * 1000
         ELSE value_raw END                            AS metric_value,
    CASE WHEN unit_raw IN ('ratio', 'percent', '%', 'pct') THEN 'percent'
         WHEN unit_raw IN ('s', 'sec', 'seconds', 'ms')    THEN 'ms'
         ELSE unit_raw END                             AS metric_unit,
    (unit_raw IN ('ratio', 's', 'sec', 'seconds'))     AS unit_converted,   -- true when we had to convert
    -- plausible-window check (rejects 1970 and 2027+), same as for incidents
    CASE WHEN event_p    BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN event_p    END AS event_ts,
    CASE WHEN received_p BETWEEN TIMESTAMP'2020-01-01' AND TIMESTAMP'2026-12-31 23:59:59' THEN received_p END AS received_ts
  FROM base
),
ranked AS (   -- duplicate event_id: keep the latest received copy (rn = 1)
  SELECT *,
    row_number() OVER (PARTITION BY event_id
                       ORDER BY received_ts DESC NULLS LAST, ingested_at DESC, record_hash) AS rn
  FROM conformed
)
SELECT r.*,
  -- seconds between the event happening and us receiving it
  unix_timestamp(r.received_ts) - unix_timestamp(r.event_ts) AS ingestion_delay_seconds,
  -- late-arriving = received more than 1 hour (3600 s) after it happened
  coalesce(unix_timestamp(r.received_ts) - unix_timestamp(r.event_ts) > 3600, false) AS is_late_arriving,
  -- HARD errors -> quarantine
  filter(array(
    CASE WHEN r.event_id IS NULL THEN 'missing_event_id' END,
    CASE WHEN r.rn > 1 THEN 'duplicate_key' END,
    CASE WHEN r.metric_missing THEN 'schema_violation:metric_missing' END,
    CASE WHEN r.event_ts IS NULL THEN 'invalid_timestamp:event_timestamp' END,
    CASE WHEN NOT r.metric_missing AND r.metric_value IS NULL THEN 'invalid_type:metric_value' END,
    CASE WHEN r.asset_id IS NULL THEN 'missing_asset_key'
         WHEN a.asset_id IS NULL THEN 'unknown_asset_key' END   -- asset must exist in silver_assets
  ), x -> x IS NOT NULL) AS dq_reasons,
  -- SOFT problems -> kept, flagged
  filter(array(
    CASE WHEN r.unit_converted THEN 'unit_converted' END,
    CASE WHEN r.received_p IS NOT NULL AND r.received_ts IS NULL THEN 'invalid_received_at' END,
    CASE WHEN coalesce(unix_timestamp(r.received_ts) - unix_timestamp(r.event_ts) > 3600, false) THEN 'late_arriving' END
  ), x -> x IS NOT NULL) AS dq_flags
FROM ranked r
LEFT JOIN data2026acc123456.team1.silver_assets a ON r.asset_id = a.asset_id;

CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.silver_monitoring_events AS
SELECT event_id, event_ts, asset_id, incident_id, source_tool, source_host, source_region,
       metric_name, metric_value, metric_unit, alert_triggered, alert_threshold, alert_level, tags,
       received_ts, ingestion_delay_seconds, is_late_arriving,
       dq_flags, source_file, batch_id, record_hash
FROM data2026acc123456.team1.silver_monitoring_events_staged
WHERE size(dq_reasons) = 0;

CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.quarantine_monitoring_events AS
SELECT event_id AS record_key, 'bronze_monitoring_events' AS source_table, explode(dq_reasons) AS rule,
       raw_record, source_file AS source_file, batch_id AS batch_id, record_hash AS record_hash,
       current_timestamp() AS processed_at
FROM data2026acc123456.team1.silver_monitoring_events_staged
WHERE size(dq_reasons) > 0;

--#####################################################################
-- GOLD LAYER  -  Team 1: Intelligent IT Incident Analytics   (Power BI ready)
--#####################################################################
-- SETUP (run ONCE in the SQL editor, not in the pipeline):
--   CREATE SCHEMA IF NOT EXISTS data2026acc123456.gold;
--
-- Reads ONLY the trusted Silver tables (data2026acc123456.silver.silver_*): rows with no hard errors.
--
-- STAR SCHEMA
--   fact_incident          grain: ONE ROW PER INCIDENT (latest version of the incident)
--   fact_monitoring_event  grain: ONE ROW PER MONITORING EVENT (unique event_id)
--   dim_date, dim_asset, dim_service, dim_team, dim_severity, dim_resolution_category
--   kpi_summary            aggregate of the 8 required KPIs (month x severity x service x team)
--   kpi_definitions, refresh_info, exception_queue, reconciliation_summary  (support tables)
--
-- SURROGATE KEYS
--   * Dimension keys (*_key, INT) = row_number() over the natural key, starting at 1.
--   * Unknown member = -1 in every dimension except dim_date (a missing/unmatched value
--     in a fact points to -1, so no fact row is ever lost in a join).
--   * dim_date.date_key = yyyymmdd (readable integer); dim_severity keys are fixed 1..4.
--   * Fact keys (incident_key, event_key) = row_number() over the business id.
--   * Keys are assigned at every refresh. Facts and dimensions are rebuilt together in the
--     same run, so they always agree. Do not copy key values into other systems.
--   * A date key is NULL when the milestone has not happened (open incident -> no resolved date).
--
-- POWER BI FRIENDLY
--   * Flags are INT 0/1 (use SUM). No arrays or structs (the SQL endpoint cannot read them).
--   * Sort columns provided: month_number, day_of_week_number, severity sort_order, criticality_sort.
--   * "As of" time for open-backlog age and open SLA breach = latest opened_at in the data
--     (not the wall clock), so the demo gives the same answer whenever you refresh it.
--#####################################################################


--#####################################################
-- Dimensions
--#####################################################

-- ---------------------------------------------------------------------
-- dim_date: one row per calendar day 2025-2027 (generated)
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.dim_date
COMMENT 'Calendar dimension, one row per day 2025-2027. date_key = yyyymmdd. Role-playing: opened, acknowledged, resolved, closed (fact_incident) and event (fact_monitoring_event). Mark as date table on full_date.'
AS
SELECT
  CAST(date_format(d, 'yyyyMMdd') AS INT)  AS date_key,
  d                                        AS full_date,
  year(d)                                  AS year,
  quarter(d)                               AS quarter_number,
  concat('Q', quarter(d))                  AS quarter_name,
  month(d)                                 AS month_number,      -- sort column for month_name
  date_format(d, 'MMMM')                   AS month_name,
  date_format(d, 'MMM')                    AS month_short,
  date_format(d, 'yyyy-MM')                AS year_month,
  weekofyear(d)                            AS iso_week,
  day(d)                                   AS day_of_month,
  dayofweek(d)                             AS day_of_week_number, -- sort column for day_name (1 = Sunday)
  date_format(d, 'EEEE')                   AS day_name,
  CASE WHEN dayofweek(d) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS day_type
FROM (SELECT explode(sequence(DATE'2025-01-01', DATE'2027-12-31', INTERVAL 1 DAY)) AS d);

-- ---------------------------------------------------------------------
-- dim_severity: fixed reference table (P1 = most severe)
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.dim_severity
COMMENT 'Incident severity. Key 1..4 = P1..P4, -1 = Unknown (missing/invalid severity with no SLA to derive it from). Sort by sort_order.'
AS
SELECT * FROM VALUES
  (1,  'P1',      'P1 - Critical', 1,  'Yes'),
  (2,  'P2',      'P2 - High',     2,  'Yes'),
  (3,  'P3',      'P3 - Medium',   3,  'No'),
  (4,  'P4',      'P4 - Low',      4,  'No'),
  (-1, 'Unknown', 'Unknown',       99, 'No')
AS t(severity_key, severity_code, severity_name, sort_order, is_high_priority);

-- ---------------------------------------------------------------------
-- dim_resolution_category
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.dim_resolution_category
COMMENT 'How an incident was resolved. resolution_group separates real fixes from no-action outcomes. Key -1 = not resolved yet / not applicable.'
AS
SELECT
  row_number() OVER (ORDER BY resolution_category) AS resolution_category_key,
  resolution_category,
  resolution_group
FROM (
  SELECT DISTINCT
    resolution_category,
    CASE WHEN resolution_category IN ('Duplicate', 'User Error', 'No Fault Found')
         THEN 'No action required' ELSE 'Fix applied' END AS resolution_group
  FROM data2026acc123456.team1.silver_incidents
  WHERE resolution_category IS NOT NULL
)
UNION ALL
SELECT -1, 'Not resolved / Unknown', 'Not applicable';

-- ---------------------------------------------------------------------
-- dim_service
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.dim_service
COMMENT 'Business services (e.g. SVC-SSO Identity / SSO). Key -1 = service unknown. Shared by both facts.'
AS
SELECT
  row_number() OVER (ORDER BY i.service_id)  AS service_key,
  i.service_id,
  coalesce(n.service_name, i.service_id)     AS service_name
FROM (
  SELECT service_id FROM data2026acc123456.team1.silver_assets    WHERE service_id IS NOT NULL
  UNION
  SELECT service_id FROM data2026acc123456.team1.silver_incidents WHERE service_id IS NOT NULL
) i
LEFT JOIN (
  SELECT service_id, max(service_name) AS service_name
  FROM data2026acc123456.team1.silver_assets
  WHERE service_id IS NOT NULL
  GROUP BY service_id
) n ON i.service_id = n.service_id
UNION ALL
SELECT -1, 'UNKNOWN', 'Unknown';

-- ---------------------------------------------------------------------
-- dim_team (manager_email deliberately excluded; use this table for row-level security)
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.dim_team
COMMENT 'Support teams (owners of assets, assignees of incidents). manager_email excluded on purpose. Key -1 = team unknown. Use for row-level security by team.'
AS
SELECT
  row_number() OVER (ORDER BY team_id)       AS team_key,
  team_id, team_name, department, location, support_hours,
  CASE WHEN on_call THEN 'Yes' ELSE 'No' END AS on_call,
  created_date
FROM data2026acc123456.team1.silver_teams
UNION ALL
SELECT -1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', CAST(NULL AS DATE);

-- ---------------------------------------------------------------------
-- dim_asset
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.dim_asset
COMMENT 'IT assets, one row per asset_id. Owner team is denormalised so the star stays flat. Hierarchy: site > asset_type > asset_name. Key -1 = asset unknown.'
AS
SELECT
  row_number() OVER (ORDER BY a.asset_id)  AS asset_key,
  a.asset_id, a.asset_name, a.asset_type, a.environment, a.site,
  a.criticality,
  CASE a.criticality WHEN 'Critical' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3 WHEN 'Low' THEN 4 ELSE 99 END AS criticality_sort,
  a.install_date, a.lifecycle_status,
  a.owner_team_id,
  coalesce(t.team_name, 'Unknown')         AS owner_team_name
FROM data2026acc123456.team1.silver_assets a
LEFT JOIN data2026acc123456.team1.silver_teams t ON a.owner_team_id = t.team_id
UNION ALL
SELECT -1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 99,
       CAST(NULL AS DATE), 'Unknown', 'UNKNOWN', 'Unknown';


--#####################################################
-- Facts
--#####################################################

-- ---------------------------------------------------------------------
-- fact_incident   GRAIN: one row per incident (latest version)
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.fact_incident
CLUSTER BY (opened_date_key, severity_key)
COMMENT 'Fact, grain = one incident. FKs: asset_key, service_key, assigned_team_key, severity_key, resolution_category_key, opened/acknowledged/resolved/closed_date_key. Flags are 0/1. Durations in minutes.'
AS
WITH asof AS (    -- snapshot time = latest opened_at in the data (deterministic, not the wall clock)
  SELECT max(opened_at) AS as_of_ts FROM data2026acc123456.team1.silver_incidents
),
calc AS (
  SELECT
    i.*,
    a.service_id AS asset_service_id,
    asof.as_of_ts,
    timestampadd(HOUR, i.sla_target_hours, i.opened_at)                         AS sla_due_at,
    i.status IN ('New', 'Acknowledged', 'In Progress')                          AS f_open,
    i.status IN ('Resolved', 'Closed')                                          AS f_resolved,
    i.status = 'Cancelled'                                                      AS f_cancelled
  FROM data2026acc123456.team1.silver_incidents i
  LEFT JOIN data2026acc123456.team1.silver_assets a ON i.asset_id = a.asset_id
  CROSS JOIN asof
),
sla AS (
  SELECT c.*,
    -- SLA judged on resolved incidents: met if resolved on or before the deadline
    CASE WHEN c.f_resolved AND c.resolved_at IS NOT NULL AND c.sla_due_at IS NOT NULL
         THEN c.resolved_at <= c.sla_due_at END AS sla_met_raw
  FROM calc c
)
SELECT
  row_number() OVER (ORDER BY s.incident_id)                 AS incident_key,
  s.incident_id,                                             -- degenerate dimension
  coalesce(da.asset_key, -1)                                 AS asset_key,
  coalesce(dsv.service_key, -1)                              AS service_key,
  coalesce(dt.team_key, -1)                                  AS assigned_team_key,
  coalesce(dsev.severity_key, -1)                            AS severity_key,
  coalesce(drc.resolution_category_key, -1)                  AS resolution_category_key,
  CAST(date_format(s.opened_at,       'yyyyMMdd') AS INT)    AS opened_date_key,       -- never NULL
  CAST(date_format(s.acknowledged_at, 'yyyyMMdd') AS INT)    AS acknowledged_date_key, -- NULL = not happened
  CAST(date_format(s.resolved_at,     'yyyyMMdd') AS INT)    AS resolved_date_key,
  CAST(date_format(s.closed_at,       'yyyyMMdd') AS INT)    AS closed_date_key,
  -- degenerate attributes
  s.status, s.category, s.root_cause, s.reported_via, s.related_incident_id,
  -- timestamps
  s.opened_at, s.acknowledged_at, s.resolved_at, s.closed_at, s.last_updated_at, s.sla_due_at,
  -- measures
  1                                                          AS incident_count,
  s.affected_users,
  s.sla_target_hours,
  CASE WHEN s.acknowledged_at IS NOT NULL
       THEN (unix_timestamp(s.acknowledged_at) - unix_timestamp(s.opened_at)) / 60.0 END AS minutes_to_acknowledge,
  CASE WHEN s.resolved_at IS NOT NULL
       THEN (unix_timestamp(s.resolved_at) - unix_timestamp(s.opened_at)) / 60.0 END     AS minutes_to_resolve,
  -- flags (0/1)
  CASE WHEN s.f_open       THEN 1 ELSE 0 END                 AS is_open,
  CASE WHEN s.f_resolved   THEN 1 ELSE 0 END                 AS is_resolved,
  CASE WHEN s.f_cancelled  THEN 1 ELSE 0 END                 AS is_cancelled,
  CASE WHEN s.severity IN ('P1', 'P2') THEN 1 ELSE 0 END     AS is_high_priority,
  CASE WHEN s.related_incident_id IS NOT NULL THEN 1 ELSE 0 END AS is_recurrence,
  CASE WHEN s.sla_met_raw = true  THEN 1 ELSE 0 END          AS is_sla_met,
  CASE WHEN s.sla_met_raw = false THEN 1 ELSE 0 END          AS is_sla_breached,
  CASE WHEN s.f_open AND s.as_of_ts > s.sla_due_at THEN 1 ELSE 0 END AS is_open_sla_breached,
  CASE WHEN s.f_cancelled                          THEN 'Cancelled'
       WHEN s.sla_met_raw = true                   THEN 'Met'
       WHEN s.sla_met_raw = false                  THEN 'Breached'
       WHEN s.f_open AND s.as_of_ts > s.sla_due_at THEN 'Open - Breached'
       WHEN s.f_open                               THEN 'Open - Within SLA'
       ELSE 'Unknown' END                                    AS sla_status,
  -- age of open incidents at the snapshot time
  CASE WHEN s.f_open THEN (unix_timestamp(s.as_of_ts) - unix_timestamp(s.opened_at)) / 3600.0 END AS backlog_age_hours,
  CASE WHEN NOT s.f_open THEN 'Not open'
       WHEN (unix_timestamp(s.as_of_ts) - unix_timestamp(s.opened_at)) / 3600.0 < 24  THEN '< 1 day'
       WHEN (unix_timestamp(s.as_of_ts) - unix_timestamp(s.opened_at)) / 3600.0 < 72  THEN '1-3 days'
       WHEN (unix_timestamp(s.as_of_ts) - unix_timestamp(s.opened_at)) / 3600.0 < 168 THEN '3-7 days'
       ELSE '> 7 days' END                                   AS backlog_age_bucket,
  -- lineage / data quality (arrays turned into text for Power BI)
  array_join(s.dq_flags, ', ')                               AS dq_flags_text,
  CASE WHEN size(s.dq_flags) > 0 THEN 1 ELSE 0 END           AS has_dq_flag,
  s.source_file, s.batch_id, s.record_hash
FROM sla s
LEFT JOIN data2026acc123456.team1.dim_asset               da   ON s.asset_id = da.asset_id
LEFT JOIN data2026acc123456.team1.dim_service             dsv  ON coalesce(s.service_id, s.asset_service_id) = dsv.service_id
LEFT JOIN data2026acc123456.team1.dim_team                dt   ON s.assigned_team_id = dt.team_id
LEFT JOIN data2026acc123456.team1.dim_severity            dsev ON s.severity = dsev.severity_code
LEFT JOIN data2026acc123456.team1.dim_resolution_category drc  ON s.resolution_category = drc.resolution_category;

-- ---------------------------------------------------------------------
-- fact_monitoring_event   GRAIN: one row per monitoring event
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.fact_monitoring_event
CLUSTER BY (event_date_key, asset_key)
COMMENT 'Fact, grain = one monitoring event. FKs: asset_key, service_key, event_date_key, incident_key (-1 = not linked to a trusted incident). Flags are 0/1.'
AS
SELECT
  row_number() OVER (ORDER BY e.event_id)                    AS event_key,
  e.event_id,                                                -- degenerate dimension
  coalesce(da.asset_key, -1)                                 AS asset_key,
  coalesce(ds.service_key, -1)                               AS service_key,
  CAST(date_format(e.event_ts, 'yyyyMMdd') AS INT)           AS event_date_key,
  hour(e.event_ts)                                           AS event_hour,
  coalesce(fi.incident_key, -1)                              AS incident_key,
  e.incident_id,
  CASE WHEN e.incident_id IS NULL    THEN 'No incident'
       WHEN fi.incident_id IS NOT NULL THEN 'Linked'
       ELSE 'Incident not in Gold' END                       AS incident_link_status,  -- e.g. incident was quarantined
  e.event_ts, e.received_ts,
  e.source_tool, e.source_host, e.source_region,
  e.metric_name, e.metric_unit, e.metric_value,
  e.alert_level, e.alert_threshold,
  1                                                          AS event_count,
  CASE WHEN e.alert_triggered = true THEN 1 ELSE 0 END       AS is_alert,
  CASE WHEN e.metric_value >= e.alert_threshold THEN 1 ELSE 0 END AS is_threshold_breach,
  e.ingestion_delay_seconds,
  CASE WHEN e.is_late_arriving THEN 1 ELSE 0 END             AS is_late_arriving,
  array_join(e.tags, ', ')                                   AS tags_text,
  array_join(e.dq_flags, ', ')                               AS dq_flags_text,
  e.source_file, e.batch_id, e.record_hash
FROM data2026acc123456.team1.silver_monitoring_events e
LEFT JOIN data2026acc123456.team1.silver_assets a  ON e.asset_id = a.asset_id
LEFT JOIN data2026acc123456.team1.dim_asset       da ON e.asset_id = da.asset_id
LEFT JOIN data2026acc123456.team1.dim_service     ds ON a.service_id = ds.service_id
LEFT JOIN data2026acc123456.team1.fact_incident   fi ON e.incident_id = fi.incident_id;


--#####################################################
-- KPI table  (the 8 KPIs required for Team 1)
--#####################################################
-- GRAIN: opened month x severity x service x assigned team. Cancelled incidents excluded.
-- Relationships in Power BI:
--   month_date_key -> dim_date[date_key] (first day of the month)
--   severity_key -> dim_severity, service_key -> dim_service, assigned_team_key -> dim_team
-- Ratios and means are stored WITH their numerator and denominator. When a report rolls up
-- to a higher level it must SUM the parts and divide (never average the stored ratios).
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.kpi_summary
COMMENT 'Team 1 KPIs by opened month, severity, service, team. Cancelled excluded. Rates and means come with numerator/denominator columns for correct re-aggregation. month_date_key joins to dim_date.'
AS
SELECT
  CAST(floor(f.opened_date_key / 100) * 100 + 1 AS INT)       AS month_date_key,
  f.severity_key,
  f.service_key,
  f.assigned_team_key,

  -- 1. Incident count
  count(*)                                                    AS incident_count,
  -- 2. Open backlog (New / Acknowledged / In Progress)
  sum(f.is_open)                                              AS open_backlog,
  -- 3. P1/P2 rate = P1+P2 incidents / incidents
  sum(f.is_high_priority)                                     AS p1_p2_incident_count,
  try_divide(sum(f.is_high_priority), count(*))               AS p1_p2_rate,
  -- 4. Mean time to acknowledge (minutes) = total minutes / acknowledged incidents
  sum(f.minutes_to_acknowledge)                               AS total_minutes_to_acknowledge,
  count(f.minutes_to_acknowledge)                             AS acknowledged_incident_count,
  try_divide(sum(f.minutes_to_acknowledge), count(f.minutes_to_acknowledge)) AS mean_time_to_acknowledge_min,
  -- 5. Mean time to resolve (minutes) = total minutes / resolved incidents
  sum(f.minutes_to_resolve)                                   AS total_minutes_to_resolve,
  count(f.minutes_to_resolve)                                 AS resolved_incident_count,
  try_divide(sum(f.minutes_to_resolve), count(f.minutes_to_resolve)) AS mean_time_to_resolve_min,
  -- 6. SLA compliance = met / (met + breached), resolved incidents only
  sum(f.is_sla_met)                                           AS sla_met_count,
  sum(f.is_sla_breached)                                      AS sla_breached_count,
  try_divide(sum(f.is_sla_met), sum(f.is_sla_met) + sum(f.is_sla_breached)) AS sla_compliance_rate,
  -- 7. Recurrence rate = incidents linked to an earlier incident / incidents
  sum(f.is_recurrence)                                        AS recurrence_count,
  try_divide(sum(f.is_recurrence), count(*))                  AS recurrence_rate,
  -- 8. Affected users
  sum(f.affected_users)                                       AS affected_users
FROM data2026acc123456.team1.fact_incident f
WHERE f.is_cancelled = 0
GROUP BY CAST(floor(f.opened_date_key / 100) * 100 + 1 AS INT),
         f.severity_key, f.service_key, f.assigned_team_key;

-- ---------------------------------------------------------------------
-- kpi_definitions: documents each KPI (name, formula, unit) for report tooltips and the data dictionary
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.kpi_definitions
COMMENT 'Business definition of every KPI: formula, unit, source columns. Use in report tooltips / info pages.'
AS
SELECT * FROM VALUES
  (1, 'Incident count',           'Number of incidents opened (excluding cancelled)',                    'count',   'incident_count'),
  (2, 'Open backlog',             'Incidents with status New, Acknowledged or In Progress',              'count',   'open_backlog'),
  (3, 'P1/P2 rate',               'P1 + P2 incidents divided by all incidents',                          'percent', 'p1_p2_incident_count / incident_count'),
  (4, 'Mean time to acknowledge', 'Average minutes from opened to acknowledged (acknowledged only)',     'minutes', 'total_minutes_to_acknowledge / acknowledged_incident_count'),
  (5, 'Mean time to resolve',     'Average minutes from opened to resolved (resolved only)',             'minutes', 'total_minutes_to_resolve / resolved_incident_count'),
  (6, 'SLA compliance',           'Resolved incidents resolved within sla_target_hours / all resolved',  'percent', 'sla_met_count / (sla_met_count + sla_breached_count)'),
  (7, 'Recurrence rate',          'Incidents linked to an earlier incident divided by all incidents',    'percent', 'recurrence_count / incident_count'),
  (8, 'Affected users',           'Sum of users affected by incidents (invalid values excluded)',        'count',   'affected_users')
AS t(kpi_id, kpi_name, definition, unit, formula);

-- ---------------------------------------------------------------------
-- refresh_info: one row for the report's "last refresh" indicator
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.refresh_info
COMMENT 'One row: when Gold was last refreshed and the data window it covers. Show in the report header.'
AS
SELECT
  current_timestamp()                                         AS gold_refreshed_at,
  (SELECT max(ingested_at) FROM data2026acc123456.team1.bronze_incidents) AS last_bronze_load_at,
  (SELECT max(opened_at)   FROM data2026acc123456.team1.fact_incident)      AS latest_incident_opened_at,
  (SELECT max(event_ts)    FROM data2026acc123456.team1.fact_monitoring_event) AS latest_event_at,
  (SELECT count(*)         FROM data2026acc123456.team1.fact_incident)      AS incident_rows,
  (SELECT count(*)         FROM data2026acc123456.team1.fact_monitoring_event) AS event_rows;


--#####################################################
-- Exceptions and reconciliation
--#####################################################

-- exception_queue: every quarantined record from all four sources (feeds the exceptions page)
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.exception_queue
COMMENT 'All quarantined records (teams, assets, incidents, monitoring events), one row per broken rule. rule_group = rule family (text before the colon).'
AS
SELECT source_table, record_key, rule, split(rule, ':')[0] AS rule_group, raw_record, source_file, batch_id, processed_at
FROM data2026acc123456.team1.quarantine_teams
UNION ALL
SELECT source_table, record_key, rule, split(rule, ':')[0], raw_record, source_file, batch_id, processed_at
FROM data2026acc123456.team1.quarantine_assets
UNION ALL
SELECT source_table, record_key, rule, split(rule, ':')[0], raw_record, source_file, batch_id, processed_at
FROM data2026acc123456.team1.quarantine_incidents
UNION ALL
SELECT source_table, record_key, rule, split(rule, ':')[0], raw_record, source_file, batch_id, processed_at
FROM data2026acc123456.team1.quarantine_monitoring_events;

-- reconciliation_summary: Bronze -> Silver -> Gold
--   row_count : bronze = silver + rejected  AND  silver = gold
--   totals    : critical totals identical in Silver and Gold
CREATE OR REFRESH MATERIALIZED VIEW data2026acc123456.team1.reconciliation_summary
COMMENT 'Row-count and critical-total reconciliation Bronze -> Silver -> Gold. status = PASS when the numbers tie out.'
AS
WITH checks AS (
  SELECT 'incidents' AS entity, 'row_count' AS check_name,
    (SELECT count(*) FROM data2026acc123456.team1.bronze_incidents)                                   AS bronze_value,
    (SELECT count(*) FROM data2026acc123456.team1.silver_incidents_staged WHERE size(dq_reasons) > 0) AS rejected_value,
    (SELECT count(*) FROM data2026acc123456.team1.silver_incidents)                                   AS silver_value,
    (SELECT count(*) FROM data2026acc123456.team1.fact_incident)                                        AS gold_value
  UNION ALL
  SELECT 'incidents', 'total_affected_users', NULL, NULL,
    (SELECT sum(affected_users) FROM data2026acc123456.team1.silver_incidents),
    (SELECT sum(affected_users) FROM data2026acc123456.team1.fact_incident)
  UNION ALL
  SELECT 'incidents', 'open_backlog', NULL, NULL,
    (SELECT count(*) FROM data2026acc123456.team1.silver_incidents WHERE status IN ('New', 'Acknowledged', 'In Progress')),
    (SELECT sum(is_open) FROM data2026acc123456.team1.fact_incident)
  UNION ALL
  SELECT 'incidents', 'kpi_summary_incident_count', NULL, NULL,
    (SELECT count(*) FROM data2026acc123456.team1.fact_incident WHERE is_cancelled = 0),
    (SELECT sum(incident_count) FROM data2026acc123456.team1.kpi_summary)
  UNION ALL
  SELECT 'monitoring_events', 'row_count',
    (SELECT count(*) FROM data2026acc123456.team1.bronze_monitoring_events),
    (SELECT count(*) FROM data2026acc123456.team1.silver_monitoring_events_staged WHERE size(dq_reasons) > 0),
    (SELECT count(*) FROM data2026acc123456.team1.silver_monitoring_events),
    (SELECT count(*) FROM data2026acc123456.team1.fact_monitoring_event)
  UNION ALL
  SELECT 'assets', 'row_count',
    (SELECT count(*) FROM data2026acc123456.team1.bronze_assets),
    (SELECT count(*) FROM data2026acc123456.team1.silver_assets_staged WHERE size(dq_reasons) > 0),
    (SELECT count(*) FROM data2026acc123456.team1.silver_assets),
    (SELECT count(*) - 1 FROM data2026acc123456.team1.dim_asset)          -- minus the Unknown member
  UNION ALL
  SELECT 'teams', 'row_count',
    (SELECT count(*) FROM data2026acc123456.team1.bronze_teams),
    (SELECT count(*) FROM data2026acc123456.team1.silver_teams_staged WHERE size(dq_reasons) > 0),
    (SELECT count(*) FROM data2026acc123456.team1.silver_teams),
    (SELECT count(*) - 1 FROM data2026acc123456.team1.dim_team)           -- minus the Unknown member
)
SELECT
  entity, check_name, bronze_value, rejected_value, silver_value, gold_value,
  CASE WHEN check_name = 'row_count'
       THEN CASE WHEN bronze_value = silver_value + rejected_value AND silver_value = gold_value THEN 'PASS' ELSE 'FAIL' END
       ELSE CASE WHEN silver_value = gold_value THEN 'PASS' ELSE 'FAIL' END END AS status,
  current_timestamp() AS checked_at
FROM checks;

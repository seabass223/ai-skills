-- .github/skills/azure-sql-dtu-profiler/scripts/collect_query_store_waits.sql
DECLARE @start_time datetime2(0) = '{{START_UTC}}';
DECLARE @end_time   datetime2(0) = '{{END_UTC}}';

;WITH
    interval
    AS
    (
        SELECT runtime_stats_interval_id
        FROM sys.query_store_runtime_stats_interval
        WHERE start_time >= @start_time
            AND end_time   <= @end_time
    ),
    waits
    AS
    (
        SELECT
            qsp.query_id,
            qws.plan_id,
            qws.wait_category_desc,
            SUM(qws.total_query_wait_time_ms) AS total_wait_ms
        FROM sys.query_store_wait_stats qws
            JOIN interval i ON i.runtime_stats_interval_id = qws.runtime_stats_interval_id
            JOIN sys.query_store_plan qsp ON qsp.plan_id = qws.plan_id
        GROUP BY qsp.query_id, qws.plan_id, qws.wait_category_desc
    ),
    waits_pivot
    AS
    (
        SELECT
            query_id,
            plan_id,
            SUM(total_wait_ms) AS wait_total_ms,
            SUM(CASE WHEN wait_category_desc = 'CPU'          THEN total_wait_ms ELSE 0 END) AS wait_cpu_ms,
            SUM(CASE WHEN wait_category_desc = 'Lock'         THEN total_wait_ms ELSE 0 END) AS wait_lock_ms,
            SUM(CASE WHEN wait_category_desc = 'IO'           THEN total_wait_ms ELSE 0 END) AS wait_io_ms,
            SUM(CASE WHEN wait_category_desc = 'Memory'       THEN total_wait_ms ELSE 0 END) AS wait_mem_ms,
            SUM(CASE WHEN wait_category_desc = 'Buffer Latch' THEN total_wait_ms ELSE 0 END) AS wait_buflatch_ms,
            SUM(CASE WHEN wait_category_desc = 'Unknown'      THEN total_wait_ms ELSE 0 END) AS wait_unknown_ms
        FROM waits
        GROUP BY query_id, plan_id
    )
SELECT
    query_id,
    plan_id,
    CAST(100.0 * wait_cpu_ms      / NULLIF(wait_total_ms,0) AS decimal(5,1)) AS wait_cpu_pct,
    CAST(100.0 * wait_lock_ms     / NULLIF(wait_total_ms,0) AS decimal(5,1)) AS wait_lock_pct,
    CAST(100.0 * wait_io_ms       / NULLIF(wait_total_ms,0) AS decimal(5,1)) AS wait_io_pct,
    CAST(100.0 * wait_mem_ms      / NULLIF(wait_total_ms,0) AS decimal(5,1)) AS wait_mem_pct,
    CAST(100.0 * wait_buflatch_ms / NULLIF(wait_total_ms,0) AS decimal(5,1)) AS wait_buflatch_pct,
    CAST(100.0 * wait_unknown_ms  / NULLIF(wait_total_ms,0) AS decimal(5,1)) AS wait_unknown_pct
FROM waits_pivot;

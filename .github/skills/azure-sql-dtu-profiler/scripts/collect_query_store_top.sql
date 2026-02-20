-- .github/skills/azure-sql-dtu-profiler/scripts/collect_query_store_top.sql
DECLARE @start_time datetime2(0) = '{{START_UTC}}';
DECLARE @end_time   datetime2(0) = '{{END_UTC}}';
DECLARE @top_n int = {{TOP_N}};

-- Top queries in a time window (Query Store)
;WITH
    base
    AS
    (
        SELECT
            qsq.query_id,
            qsp.plan_id,
            SUM(rs.count_executions) AS executions,
            SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms,
            SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,
            SUM(rs.avg_logical_io_reads * rs.count_executions)  AS total_logical_reads,
            SUM(rs.avg_logical_io_writes * rs.count_executions) AS total_logical_writes,
            MAX(rs.max_duration) / 1000.0 AS max_duration_ms,
            LEFT(REPLACE(REPLACE(qst.query_sql_text, CHAR(13), ' '), CHAR(10), ' '), 4000) AS sample_sql_text
        FROM sys.query_store_runtime_stats rs
            JOIN sys.query_store_runtime_stats_interval rsi
            ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
            JOIN sys.query_store_plan qsp
            ON qsp.plan_id = rs.plan_id
            JOIN sys.query_store_query qsq
            ON qsq.query_id = qsp.query_id
            JOIN sys.query_store_query_text qst
            ON qst.query_text_id = qsq.query_text_id
        WHERE rsi.start_time >= @start_time
            AND rsi.end_time   <= @end_time
        GROUP BY qsq.query_id, qsp.plan_id, qst.query_sql_text
    )
SELECT TOP (@top_n)
    *
FROM base
ORDER BY
  CASE '{{ORDER_BY}}'
    WHEN 'cpu'          THEN total_cpu_ms
    WHEN 'duration'     THEN total_duration_ms
    WHEN 'reads'        THEN total_logical_reads
    WHEN 'writes'       THEN total_logical_writes
    WHEN 'max_duration' THEN max_duration_ms
    ELSE total_cpu_ms
  END DESC;

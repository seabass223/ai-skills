-- .github/skills/azure-sql-dtu-profiler/scripts/collect_query_store_timeseries.sql
-- Time-series for sparklines per query/plan (avg duration per bucket)
DECLARE @start_time datetime2(0) = '{{START_UTC}}';
DECLARE @end_time   datetime2(0) = '{{END_UTC}}';
DECLARE @bucket_min int = {{BUCKET_MINUTES}};

SELECT
    qsq.query_id,
    qsp.plan_id,
    CONVERT(varchar(19),
        DATEADD(minute, DATEDIFF(minute, '20000101', rsi.start_time) / @bucket_min * @bucket_min, '20000101')
    , 120) AS bucket_utc,
    CAST(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions),0) / 1000.0 AS decimal(18,2)) AS avg_duration_ms
FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi
    ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan qsp
    ON qsp.plan_id = rs.plan_id
    JOIN sys.query_store_query qsq
    ON qsq.query_id = qsp.query_id
WHERE rsi.start_time >= @start_time
    AND rsi.end_time   <= @end_time
GROUP BY
    qsq.query_id,
    qsp.plan_id,
    DATEADD(minute, DATEDIFF(minute, '20000101', rsi.start_time) / @bucket_min * @bucket_min, '20000101')
ORDER BY bucket_utc ASC;

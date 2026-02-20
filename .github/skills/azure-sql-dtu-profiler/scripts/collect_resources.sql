-- .github/skills/azure-sql-dtu-profiler/scripts/collect_resource.sql
-- Read-only: Resource pressure series (prefers high-res dm_db_resource_stats for ~last hour)
DECLARE @start_time datetime2(0) = '{{START_UTC}}';
DECLARE @end_time   datetime2(0) = '{{END_UTC}}';
DECLARE @bucket_min int = {{BUCKET_MINUTES}};

;WITH
    src
    AS
    (
        SELECT
            end_time,
            avg_cpu_percent      AS cpu_percent,
            avg_data_io_percent  AS data_io_percent,
            avg_log_write_percent AS log_io_percent,
            avg_memory_usage_percent AS memory_percent
        FROM sys.dm_db_resource_stats
        WHERE end_time >= @start_time
            AND end_time <= @end_time
    ),
    b
    AS
    (
        SELECT
            DATEADD(minute, DATEDIFF(minute, '20000101', end_time) / @bucket_min * @bucket_min, '20000101') AS bucket_utc,
            AVG(cpu_percent)     AS cpu_percent,
            AVG(data_io_percent) AS data_io_percent,
            AVG(log_io_percent)  AS log_io_percent,
            AVG(memory_percent)  AS memory_percent
        FROM src
        GROUP BY DATEADD(minute, DATEDIFF(minute, '20000101', end_time) / @bucket_min * @bucket_min, '20000101')
    )
SELECT
    CONVERT(varchar(19), bucket_utc, 120) AS bucket_utc,
    CAST(cpu_percent     AS decimal(5,1)) AS cpu_percent,
    CAST(data_io_percent AS decimal(5,1)) AS data_io_percent,
    CAST(log_io_percent  AS decimal(5,1)) AS log_io_percent,
    CAST(memory_percent  AS decimal(5,1)) AS memory_percent
FROM b
ORDER BY bucket_utc ASC;

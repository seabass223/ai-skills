---
name: azure-sql-dtu-profiler
description: Pull Azure SQL Query Store + resource (DTU-ish) pressure metrics for a time window and render a compact Markdown report with sparklines + ranked offender cards (CPU/duration/reads + Query Store wait categories).
---

# azure-sql-dtu-profiler (Agent Skill)

You are a performance triage assistant for **Azure SQL Database (DTU model)**.  
When asked, you generate a **quick visual report** showing:

- **DTU-ish pressure** over time (avg/max/peak for CPU/Data IO/Log IO/Memory, plus derived DTU = max(CPU, Data IO, Log IO))
- **Top problematic queries** (ranked by total CPU by default, switchable)
- Per query/plan “cards” including:
  - executions, total/avg/max duration, total CPU, reads/writes
  - **Query Store wait profile** (CPU / Lock / IO / Memory / Buffer Latch / Unknown)
  - a short SQL sample

The output is intended to be readable in **GitHub Copilot Chat** (Markdown).  
If the user requests HTML, generate it as an additional artifact file.


---

## How to use (what you should do when prompted)

### 1) Infer the time window
- If the user specifies a window (examples: “last 2 hours”, “last 30m”, “since 1pm”), use it.
- If you cannot confidently infer, default to **last 1 hour**.
- Always operate in **UTC** internally.

### 2) Run the report script
Run PowerShell script `scripts/run_report.ps1` via `pwsh`. Prefer it over ad-hoc commands.

**Required inputs** (via environment variables, never hardcode secrets):
- `SKILL_AZURE_SQL_SERVER` (example: `myserver.database.windows.net` or `myserver`)
- `SKILL_AZURE_SQL_DATABASE` (example: `MyDb`)

These should be defined in the workspace `.env` file (which is git-ignored).
Before invoking the script, **source the `.env` file** so the variables are available to `pwsh`.

**Auth** (in priority order):
1. **SQL auth** – If `SKILL_SQL_READONLY_USER` and `SKILL_SQL_READONLY_PASSWORD` are set in `.env`, the script uses SQL authentication directly.
2. **Entra ID** – Otherwise, falls back to the local `az` login context. The script obtains an access token from Azure CLI for `https://database.windows.net/`. The user must be logged in via `az login` before running the script.

### 2a) Invocation pattern

Always use this pattern to load env vars and run the script in a **bash** shell:

```bash
set -a && source .env && set +a && \
  pwsh -NoProfile -File .github/skills/azure-sql-dtu-profiler/scripts/run_report.ps1 \
    -Window <window> -BucketMinutes <bucket> -Top <n> -OrderBy <metric>
```

Example — last 6 hours, 15-min buckets, top 5 by CPU:

```bash
set -a && source .env && set +a && \
  pwsh -NoProfile -File .github/skills/azure-sql-dtu-profiler/scripts/run_report.ps1 \
    -Window 6h -BucketMinutes 15 -Top 5 -OrderBy cpu
```

If the terminal is **PowerShell** instead of bash, load the `.env` manually:

```powershell
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process')
    }
}
& .github/skills/azure-sql-dtu-profiler/scripts/run_report.ps1 -Window 6h -BucketMinutes 15
```

**Important notes**:
- The `.env` file is ignored by Copilot (gitignored) — you cannot read it directly. Just `source` it from this skills directory.
- If the 1-hour default window returns no Query Store data, suggest widening to `-Window 6h` or `-Window 24h` with larger buckets (e.g. `-BucketMinutes 15` or `-BucketMinutes 30`).
- `sys.dm_db_resource_stats` only retains ~1 hour of high-resolution data; for longer windows the resource pressure section may have fewer data points.

### 3) Safety / guardrails (non-negotiable)
- Only run the `.sql` files shipped with this skill.
- These queries must remain **read-only**.
- If asked to “fix” performance by changing DB objects, respond with advice only.
- If asked to run write operations, refuse and explain: “This skill is read-only by design.”

### 4) Output
- The report is written to `artifacts/azure-sql-dtu-profiler_report.md`. If a file with that name already exists, a sequential number is appended (e.g. `_1.md`, `_2.md`, etc.).
- The script prints the actual output path to stderr (`Report written to: ...`) — always reference the **actual path** shown in the script output, not a hardcoded name.
- Read the written file and return the Markdown contents directly in chat (and optionally link the artifact path).
- If multiple DBs are requested, generate one report per DB.

---

## Default presentation rules

### Pressure card (always first)
Show a compact block like:

| Metric     | Avg   | Max   | Peak Bucket (UTC)   |
|------------|-------|-------|---------------------|
| DTU-ish %  | 12.3% | 45.6% | 2026-02-18 14:30:00 |
| CPU %      | 10.1% | 42.0% | 2026-02-18 14:30:00 |
| Data IO %  | 5.2%  | 18.3% | 2026-02-18 14:15:00 |
| Log IO %   | 2.1%  | 8.5%  | 2026-02-18 14:30:00 |
| Memory %   | 15.0% | 22.4% | 2026-02-18 14:45:00 |

### Offender cards (Top N)
Default: Top **10** queries by **total CPU**.
Also include summary “Top 3 by duration” and “Top 3 by reads” if different.
**Ordering and coverage rules (non-negotiable):**
- Always present offender cards in their **ranked order** (#1, #2, #3 … #N). Never reorder them based on perceived interest or severity.
- **Never skip a rank.** Every query in the Top N list must appear in the chat commentary. Do not silently omit #1, #5, or any other entry because it seems less interesting.
- If you choose to call out specific queries as especially notable, you may add a brief "Highlights" section 
**after** the full ranked list — but the full list must still be shown in order.

Each card should include:
- query_id / plan_id
- executions
- total_cpu_ms, total_duration_ms, max_duration_ms
- total_logical_reads / writes
- **wait profile** percentages (CPU/Lock/IO/Memory/BufferLatch/Unknown)
- sample SQL (single line, truncated) or a synopsis of the query if SQL is too long or not available. This one is critical so the user can understand what the query is doing at a glance.

### Highlights & Recommendations table (always last)
After the full ranked offender list, always append a **Highlights & Recommendations** table that synthesises the most actionable findings. This table must:

- Use traffic-light dot emojis to signal priority: 🔴 High / 🟠 Medium / 🟡 Low
- Include one row per notable query or pattern (not one row per offender card — consolidate where the same root cause applies)
- Use the following columns:

| Priority | Query | Issue | Action |
|----------|-------|-------|--------|
| 🔴 High | #N — short label | Root cause in plain English | Concrete next step |
| 🟠 Medium | #N — short label | Root cause | Concrete next step |
| 🟡 Low | #N — short label | Root cause | Concrete next step |

**Priority assignment rules:**
- 🔴 High — extreme reads (>10M per window), extreme duration-to-CPU ratio (duration >> CPU suggests heavy waits), BufLatch or Lock wait % > 40%, or full-scan views with no filter (`SELECT *` from a view/large table).
- 🟠 Medium — high CPU wait % (> 30%), persistent memory grant pressure (Mem wait > 70% across multiple queries), high-frequency polling patterns (>5K execs, low per-exec cost but large aggregate).
- 🟡 Low — page-level contention, competing plan shapes for the same query_id, minor cardinality issues.

**Action column rules:**
- Be specific and actionable: name the index column, the hint, the statistic, or the structural change.
- Do not use vague advice like "optimize the query" or "review the plan".
- Prefer short imperative phrases: "Add index on `SomeId`", "Force plan via QS", "Rebuild stats on `AnotherId`".

---

## What to do when something is missing

- If Query Store views return nothing (Query Store disabled), say so and still show resource pressure stats.
- If wait stats are unavailable, omit wait profile and proceed.

---

## Examples of user prompts you must handle

1) “Use azure-sql-dtu-profiler for the last 2 hours.”
2) “Run DTU profiler since 14:00 UTC, bucket 5 minutes.”
3) “Show top queries by reads instead of CPU.”
4) “Focus on a single query_id 8412 and explain why it’s slow.”

---

## Script contract (what the runner supports)

`scripts/run_report.ps1` supports:

- `-Window` (default `1h`, examples: `30m`, `2h`)
- `-BucketMinutes` (default `5`)
- `-Top` (default `5`)
- `-OrderBy` (default `cpu`, options: `cpu|duration|reads|writes|max_duration`)
- `-OutDir` (default `artifacts`)

If user asks for “last 2 hours”, run: `-Window 2h`

---

## Permissions guidance (for humans)
The DB identity used by Entra should be least-privilege. Typically it needs:
- `VIEW DATABASE STATE`
- Query Store read access (usually covered once Query Store is on and you can read its catalog views)

Do not broaden permissions in this skill.

---

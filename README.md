# AI Agent Skills

Public agent skills for use with AI coding assistants (GitHub Copilot, Claude, etc.). Skills live under `.github/skills/` and are activated by referencing them in a prompt.

## Prerequisites

- **`pwsh` (PowerShell 7+)** must be on your `PATH`. Skills that run scripts invoke `pwsh` directly.
- A **`.env` file** in the repo root must be populated with the environment variables required by each skill (see per-skill docs below). The `.env` file is git-ignored — never commit secrets.

---

## Skills

### `azure-sql-dtu-profiler`

<img src="images/az-sql.jpg" width="400" alt="Azure SQL DTU Profiler" />

**Path:** `.github/skills/azure-sql-dtu-profiler/SKILL.md`

Pulls Azure SQL Query Store and resource pressure metrics for a configurable time window and renders a compact Markdown report with sparklines and ranked offender cards.

**What it produces:**
- DTU-ish pressure over time (CPU / Data IO / Log IO / Memory)
- Top N slow/expensive queries ranked by CPU, duration, or reads
- Per-query wait profiles (CPU, Lock, IO, Memory, Buffer Latch)
- Highlights & Recommendations table with traffic-light priorities

**Required `.env` variables:**

```env
SKILL_AZURE_SQL_SERVER=<yourserver>.database.windows.net
SKILL_AZURE_SQL_DATABASE=<yourdb>
# SQL auth (optional — falls back to `az login` Entra context if omitted)
SKILL_SQL_READONLY_USER=<readonly_user>
SKILL_SQL_READONLY_PASSWORD=<readonly_password>
```

**Example prompt:**
> "Use azure-sql-dtu-profiler for the last 2 hours, top 10 queries by reads."

---

## Adding a new skill

1. Create a directory under `.github/skills/<skill-name>/`.
2. Add a `SKILL.md` with a YAML front-matter block (`name`, `description`) and instructions for the agent.
3. Document required `.env` variables in this README.

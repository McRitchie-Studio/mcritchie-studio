# Nightly Sync

## Purpose

A scheduled job that runs nightly to keep agent data fresh and system health in check.

## Planned Tasks

1. **Usage Aggregation** — Roll up daily usage into weekly/monthly summaries
2. **Stale Task Detection** — Flag tasks stuck in `building` for >24 hours
3. **Agent Health Check** — Verify all agents have reported activity in the last 24 hours
4. **Error Log Pruning** — Archive error logs older than 30 days
5. **Activity Digest** — Generate daily summary of all agent activity

## Implementation

Not yet implemented. When ready:
- Use `whenever` gem or system cron
- Create a `NightlySyncJob` in `app/jobs/`
- Log each sync step as an Activity with type `data_sync`
- Report usage via the API

## Manual Trigger

```bash
bin/rails runner "NightlySyncJob.perform_now"
```

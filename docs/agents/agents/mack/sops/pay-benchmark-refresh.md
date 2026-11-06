# Pay Benchmark Refresh: market pay data for the Industries pay page
<!-- registry: refresh the BLS wage percentiles behind /admin/pay, check them, and flag anyone below their role's target -->

## Status: Active

Alex McRitchie asked for it on 2026-11-05: "a SOP for refreshing pay rate data and
a UI where I can see where my employees chart to their role." The UI is
`/admin/pay` on McRitchie Industries (task `admin-pay-benchmark-page`). He gave
this SOP to Mack, the CFO, the same day. His goal is the **top 25%**: each role's
target is the 75th percentile unless he sets another.

This SOP stands alone; every command is inline. Any agent may run it.

**Depends on** the McRitchie Industries task `admin-pay-benchmark-page`
(`lib/tasks/pay.rake`, `/admin/pay`). Until that task ships to production, the
commands below do not exist there.

**Drift** means an active employee whose hourly rate is below their role's target
wage: the wage at the role's target percentile (the 75th unless Alex McRitchie set
another). The page marks each one **Below target** and shows the gap. Drift goes to
Alex McRitchie; he decides raises.

## When to run

- **Once a year, in April or May.** BLS publishes each May survey (OEWS) the next
  spring. Check that a new year exists before you run: open
  https://www.bls.gov/oes/tables.htm and look for the newest "May <year>" release.
- **When a role is added** whose market and occupation (SOC) have no benchmark yet.
  The pay page says "No benchmark yet" on that role.
- **When Alex McRitchie asks.**

Do not run it to probe. The keyless BLS API allows 25 requests a day per IP.

## What lives where

| Thing | Where |
|---|---|
| The page | https://mcritchie.industries/admin/pay (admins only) |
| Markets and benchmarks | `/admin/pay/markets` |
| The refresh | `bin/rails pay:refresh_benchmarks` in the Industries app (Heroku app `mcritchie-industries`) |
| The starter roles and markets | `bin/rails pay:seed_standards` (idempotent; holds no pay) |
| App notes | `mcritchie-industries/docs/pay.md` |

Real names and pay live only in the production database. Never write a person's
rate into a repo, a doc, a task, a memory or a chat summary that leaves the session.

## Steps

1. **Narrate.** Open a `bin/agent-activity` activity for the refresh.
2. **Seed once.** On a fresh database only (no roles on the page), run:
   ```bash
   heroku run bin/rails pay:seed_standards -a mcritchie-industries
   ```
3. **Refresh.**
   ```bash
   heroku run bin/rails pay:refresh_benchmarks -a mcritchie-industries
   ```
   Each BLS market prints a line: `<market>: N benchmarks upserted`, and names any
   occupation with no BLS data. A `REFRESH FAILED` line is captured to ErrorLog and
   the task exits non-zero. A "daily threshold" message means the 25-request
   limit; wait a day, do not retry.
4. **Check two numbers against bls.gov.** Pick two benchmarks on
   `/admin/pay/markets`, one metro and one national-industry. Compare their median
   with the BLS table for that area and occupation, reached from
   https://www.bls.gov/oes/tables.htm (metro and national-industry tables). If either differs,
   stop and report; do not hand-edit BLS rows.
5. **Refresh the manual markets.** A manual market (for example, *Rig welder
   rates*) does not refresh itself. For each, find at least two current sources
   (job postings, a union scale, a quote) and add a benchmark for the new year
   with the median and any percentiles the sources support. Put the source link
   on the row. A rig rate includes the welder's truck and equipment; say so in
   the market's notes rather than mixing it into a wage-only row.
6. **Read the page.** Open `/admin/pay`. List every employee whose status reads
   **Below target**, with role, percentile and the gap in dollars an hour.
7. **Report to Alex McRitchie** in chat (STE-80, idea first):
   - which survey year is now live, and what moved since last year;
   - who is below target and by how much an hour, read from the page;
   - which manual markets you updated, and their sources.

   He decides raises. You never change an employee's pay row unless he asks for
   that change in the session.
8. **Close the activity.** Keep names and rates out of the activity outcome and
   any handoff: give the count below target there, and the names only in chat.

## Adding a market or role

- **A new BLS market:** `/admin/pay/markets` → *Add market* → Source *BLS OEWS*.
  Area type M (metro, 7-digit code such as `0019740` for Denver), S (state, such as
  `0800000` for Colorado) or N (national, `0000000`). Industry is a 6-digit NAICS
  code, or `000000` for all industries. Then run step 3.
- **A new role or variant:** `/admin/pay` → *Add role*. Variants of one job (Shop,
  Pipeline, Rig) share the family (Welder) and differ by variant, market and SOC.

## Limits

- Benchmarks are survey wages, straight time. They exclude overtime, bonuses and
  benefits. The pay page compares base hourly pay only.
- The page interpolates percentiles between published points. Read them as
  approximate, and say so when you quote one.
- An all-industry general-manager benchmark includes large firms. For a small
  shop, Alex McRitchie may set that role's target below the 75th; ask, do not
  assume.

# Hub Web Memory: the Allocator Change and Its Measurement Plan

**Task:** [`hub-web-memory-stays-under`](https://mcritchie.studio/tasks/hub-web-memory-stays-under).
**Owner:** Steffon. **Status:** code shipped through review; the Heroku config change
waits for Alex's go-ahead and runs in the release lane.

The hub's production web dyno (`mcritchie-studio`, one Standard-2X, 1 GB) climbs
with traffic and crossed its quota three times in six days. This page records the
diagnosis, the allocator choice, the exact command, the rollback, and how to judge
the result with the Heroku Metrics API.

## The symptom

Web runs Puma with 2 workers × 3 threads, `preload_app` on (`config/puma.rb`).
Memory is flat when idle and climbs with traffic: +190 MB over 2.5 hours at
4.5-6.3k requests/hour. Over 2026-09-30 to 2026-10-06 the 1 GB quota was exceeded
three times: 2026-10-01 peaked at 1,082 MB plus 75 MB swap, and 2026-10-05/06 at
1,009-1,034 MB, each 3-5 hours after a restart. The shape (step growth under load,
no growth at idle, reset on restart) points at allocator fragmentation across
threads more than at a Ruby-level leak.

**Do not set `WEB_CONCURRENCY=1`.** The 2026-08-09 postmortem: 3 total
concurrency produced 2,293 H12s in under three minutes. Fewer workers trades a
memory problem for an outage.

## What the dyno already runs (measured 2026-10-06)

Probed in a one-off dyno (`heroku run -a mcritchie-studio --size=standard-1x`):

| Fact | Value |
|------|-------|
| Stack | `heroku-26` (Cedar), buildpacks `heroku/nodejs` then `heroku/ruby` |
| `MALLOC_ARENA_MAX` | **already `2`**, set by the Ruby buildpack's `.profile.d/ruby.sh`: `export MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-2}` |
| jemalloc | `libjemalloc2` 5.3.0 is in the stack image at `/usr/lib/x86_64-linux-gnu/libjemalloc.so.2` |
| `LD_PRELOAD` of that path | maps into a Ruby 3.3.11 process (read from `/proc/self/maps`) |
| Ruby linked with jemalloc | no (`RbConfig::CONFIG["MAINLIBS"]` has no jemalloc) |
| Postgres | `essential-1`, hard 20-connection limit |

## The choice: jemalloc via `LD_PRELOAD`

**`MALLOC_ARENA_MAX=2` is not a remedy here, because it is already in effect.** The
growth above happened with it set. Setting it again changes nothing.

**jemalloc is the change.** It fragments far less than glibc malloc under a
multi-threaded Ruby, and on `heroku-26` it costs no buildpack and no Aptfile: the
library ships in the stack image, so the whole change is one config var.

- **No third-party buildpack.** The usual route (a community jemalloc buildpack)
  adds a supply-chain dependency to the production build. Not needed here.
- **Reviewable in code:** `AllocatorReport` (`lib/allocator_report.rb`) and its
  initializer log one line per production boot naming the malloc the process
  ACTUALLY mapped, read from `/proc/self/maps`, not from `ENV`. The pin test is
  `test/lib/allocator_report_test.rb`.
- **Scope:** a config var reaches every process type: web, worker (`bin/jobs`),
  the release phase, and `heroku run` consoles. The worker benefits the same way.
- **Failure mode is benign:** if a future stack moves the library, `ld.so` prints
  `object ... cannot be preloaded ... ignored` and the process runs on glibc. The
  boot line then reads `allocator=glibc`, which is how the release lane notices.
- **Not changed:** `MALLOC_CONF` stays unset (jemalloc defaults) for the first
  measurement, so one variable moves at a time.

## The commands (release lane, after Alex's go-ahead)

Steffon runs these. No agent runs them without Alex's explicit go-ahead in session.

```bash
# 0. Baseline first (see "Measure" below); save the output.

# 1. QA smoke: boots on jemalloc, /up answers.
heroku config:set LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 -a mcritchie-studio-qa
heroku logs -a mcritchie-studio-qa -n 300 | grep '\[allocator\]'   # expect allocator=jemalloc
curl -fsS -o /dev/null -w '%{http_code}\n' https://mcritchie-studio-qa.herokuapp.com/up

# 2. Production. config:set restarts every dyno (a new release).
heroku config:set LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 -a mcritchie-studio
heroku releases -a mcritchie-studio -n 2                          # a new vN names LD_PRELOAD
heroku logs -a mcritchie-studio -n 500 | grep '\[allocator\]'     # web AND worker: allocator=jemalloc
curl -fsS -o /dev/null -w '%{http_code}\n' https://mcritchie.studio/up
```

Read the QA host from `heroku domains -a mcritchie-studio-qa` if the herokuapp URL
does not answer. The boot line looks like:

```text
[allocator] allocator=jemalloc ld_preload=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 malloc_arena_max=2 malloc_conf=- pid=4
```

`malloc_arena_max=2` still prints because the buildpack exports it; jemalloc
ignores it.

**Rollback** (one command, restarts the dynos onto glibc):

```bash
heroku config:unset LD_PRELOAD -a mcritchie-studio
```

Roll back on any of: boot crash or R10, `/up` not 200, an error-rate rise in
`ErrorLog` after the release, or peak memory no better at the 72-hour read.

## Measure: before and after with the Metrics API

The Metrics API is the only memory reading; `Process running mem=` log lines
appear only beside an R14 (`docs/agents/modules/deployment.md`, Reading State From
Heroku). It needs no extra tooling, only the Heroku API key.

**Windows.** Take the baseline as the 72 hours BEFORE the config change and the
comparison as the 72 hours AFTER it, starting the after window one hour after the
release so the boot spike drops out. Keep the same weekdays where possible: if the
change lands on a Tuesday, compare against the previous Tuesday-to-Friday instead
of the weekend. 72 hours covers several 3-5 hour climbs and at least two daily
dyno cycles. A deploy inside either window resets memory: note it, and extend the
window rather than averaging across it.

**Normalize by traffic.** Read the router request counts for the same windows and
compare memory per traffic level, not raw: a quiet after-window proves nothing.

**The numbers to record, for web (and worker as a secondary):**

| Metric | Series | Definition |
|--------|--------|------------|
| Peak | `memory.total.bytes.max` | maximum over the window |
| Steady | `memory.total.bytes.max` | median (p50) over the window |
| Climb | `memory.total.bytes.max` | value about 4 hours after each restart minus the value 1 hour after it |
| Swap | `memory.swap.bytes.max` | maximum, and how many buckets are non-zero |
| Over quota | `memory.total.bytes.max` vs `memory.quota.bytes.max` | number of buckets above quota; plus `R14` lines in `heroku logs` |
| Traffic | `router/status` | total requests in the window, and the peak hour |

```bash
APP=mcritchie-studio
APP_ID=$(heroku apps:info -a $APP --json | ruby -rjson -e 'puts JSON.parse(STDIN.read)["app"]["id"]')
START=2026-10-03T00:00:00Z; END=2026-10-06T00:00:00Z   # set to the window
for P in dyno/memory router/status; do
  curl -s -H "Authorization: Bearer $HEROKU_API_KEY" \
       -H "Accept: application/vnd.heroku+json; version=3" \
       "https://api.metrics.heroku.com/metrics/$APP_ID/$P?process_type=web&start_time=$START&end_time=$END&step=10m" \
       > "web-${P//\//-}.json"
done
ruby -rjson -e '
  d = JSON.parse(File.read("web-dyno-memory.json"))["data"]
  mb = ->(x) { (x.to_f / 1_048_576).round }
  tot = d["memory.total.bytes.max"].compact.reject(&:zero?).sort
  swap = d["memory.swap.bytes.max"].compact
  quota = d["memory.quota.bytes.max"].compact.max
  r = JSON.parse(File.read("web-router-status.json"))["data"]
  reqs = r.values.flatten.compact.sum
  puts "peak=#{mb[tot.last]}MB steady=#{mb[tot[tot.size / 2]]}MB " \
       "swap_max=#{mb[swap.max]}MB swap_buckets=#{swap.count(&:positive?)} " \
       "over_quota_buckets=#{tot.count { |v| v > quota }} requests=#{reqs}"'
```

Run it from a scratch directory; it writes two JSON files there. Never print the
API key; `HEROKU_API_KEY` comes from `~/.zprofile` like every other Heroku read.

**Baseline already taken (24 hours to 2026-10-07 01:49 UTC, 10-minute buckets):**
peak 1,034 MB, steady (p50) 799 MB, swap max 26 MB in 27 of 145 buckets, quota
1,024 MB. Re-take the full 72-hour baseline right before the change; this one is
the reference shape, not the comparison.

**Success** is all of: peak under 900 MB (10% under quota) for the whole after
window, zero over-quota buckets, zero swap buckets, and a steady value no worse
than the baseline at comparable traffic. If peak drops but the 4-hour climb is
unchanged, the growth is a real leak, not fragmentation: open a heap investigation
task instead of tuning further.

**If jemalloc helps but not enough,** the next single step is `MALLOC_CONF`
tuning (for example `background_thread:true,dirty_decay_ms:1000`), measured the
same way. Raising workers or the dyno size is a separate decision bounded by the
20-connection budget in `config/puma.rb`.

## Related change in the same task

Agent-telemetry bodies (`input`, `output`, `preamble`, `prompt`) no longer reach
the request log for `api/v1/agent_actions` and `api/v1/agent_activities`
(`app/controllers/concerns/telemetry_log_filter.rb`). Measured 2026-10-06 over
1,066 web log lines: 25 `agent_actions#create` requests logged 167 KB of
parameters, each body printed twice (top level and the params-wrapper copy).

GitHub webhook payloads are now the largest request-log lines (71 deliveries
logged 713 KB in the same sample). They are outside this task; a follow-up can
filter them the same way.

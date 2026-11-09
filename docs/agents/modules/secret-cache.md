# Secret cache: expiring credentials, read locally first
<!-- registry: read, refresh, forget and recover cached expiring credentials; 1Password is the fallback -->

**Purpose.** Credentials that expire or rotate are read from a local folder first.
1Password (`op`) is the fallback: it is read only on a miss, after an expiry, or
for a read inside an entry's refresh window. Each read is bounded, and when `op`
fails there is a written contingency.

**Why (Alex McRitchie, 2026-10-27).** On the morning of 2026-10-27 `op` hung from
06:14 to 08:17 MDT and every ship waited on it. In the fourteen days before, about
77% of 2,405 `op` reads were `gh-token`: the GitHub App credentials that mint a
token that lives one hour.

## Where it lives

| Fact | Value |
|---|---|
| Folder | `/Users/alex/projects/.secret-cache/` (`<projects>/.secret-cache`), top-level, **not** inside `.agents/`, because local apps, desks and workflows on this Mac read it too |
| Modes | folder `0700`, files `0600`. The tooling **refuses** a wider mode, on read and on write, and names the `chmod` fix |
| Files | each cache file must be a regular file this user owns. The tooling **refuses** a symlink or a file owned by another account. Writes go to a new temp file opened `O_EXCL \| O_NOFOLLOW` under a random name, then a rename |
| Admin vault | **nothing from an admin vault is ever written here.** An `op-item` entry whose vault is `studio-agents-admin` (or `MCR_OP_VAULT_ADMIN`), or a GitHub slot for an admin-fed identity (`github.deployer`), is refused with `SecretCache::AdminVaultRefused`. The classic `bin/secret <vault> <item>` read of such an entry runs uncached |
| Git | never inside a repository; the tooling refuses a folder with a real repository at or above it (a `.git` file, or a `.git` folder holding a HEAD; a stray `.git` folder such as `~/.git` here does not count) |
| Backup | Time Machine may back it up; it is not excluded |
| Production | **Heroku dynos cannot read it.** It is a file on this Mac. An app in production keeps its credentials in its config vars |
| Override | `MCR_SECRET_CACHE_DIR` (tests); else `CLAUDE_PROJECTS_DIR/.secret-cache`; else `~/projects/.secret-cache` |
| Code | `bin/lib/secret_cache.rb` (`SecretCache`), `bin/lib/secret_cache_cli.rb`, `bin/secret`, `bin/gh-token`; soul sets: `config/soul_secret_sets.yml`, `bin/lib/soul_secrets.rb` (`SoulSecrets`), `bin/shims/op-cache/op` |

The folder holds a `README.md` and a `manifest.json` written by the tooling, plus
one file per cached secret. The README restates the rules for anyone who opens the
folder. The manifest names each entry and its metadata, **never a value**.

**What is not here.** Environment secrets (`~/.zprofile`, `~/.zprofile.admin`,
Heroku config) are meant to be stable. They stay where they are
([`credentials.md`](credentials.md)).

## The entries

| Name | What | Lifetime · refresh window | On disk |
|---|---|---|---|
| `github.agent` | GitHub App installation token, `github.mcritchie-agent` | 60 min · the last 10 min | `github-tokens.json` (two slots, toggled) |
| `github.deployer` | GitHub App installation token, `github.mcritchie-admin` | 60 min · the last 10 min | **never**: minted per call, so a build lane cannot lift it off disk (`bin/gh-token` `CACHEABLE_IDENTITIES`; a write is refused as `AdminVaultRefused`) |
| `harness-key` | this machine's harness key (`bin/harness-key`) | until revoked on the board | `harness-key.json` |

Each manifest entry carries `lifetime`, `expires_at` (stamped on mint),
`refresh_window`, `source` (the 1Password item), `owner`, `readers`, `on_expired`,
and `contingency`. Edits you make to an entry are kept. A default the file lacks is
added back.

**Long-lived 1Password items are cached only when named.** An entry of kind
`op-item` (`vault`, `item`, `field`, `lifetime_seconds`, `refresh_window_seconds`)
makes `bin/secret <vault> <item> [field]` serve that item from the folder. None are
named by default. To choose one, read the data first: since 2026-10-27 every
`bin/secret` read records its item in the read log (the `via` column reads
`secret:<vault>/<item>`; query with `bin/op-reads`). A read the cache answers is logged too, with the action `cache-hit`, so quota spend and cache hits stay apart.

## The one read path: `bin/secret`

```bash
bin/secret status                        # each entry's time left in plain words; never a value
bin/secret get github.agent              # the value on stdout: cache, else a bounded op read and write-back
bin/secret refresh github.agent [--if-under 45]   # mint now, or only when under 45 min is left
bin/secret forget github.agent           # drop one entry; the next read fetches it fresh (MCR_SECRET_CACHE_DIR is honoured)
bin/secret forget --source <1Password item>       # drop every entry that item feeds (rotation)
bin/secret contingency github.agent      # the ordered steps for when op fails or hangs
bin/secret migrate                       # adopt the legacy .agents caches (idempotent)
bin/secret prewarm                       # before a long run: refresh tokens with under 45 min left
bin/secret warm <soul> [--manifest F] [--only a,b]   # warm a soul's set: one bounded op pass
bin/secret sets                          # every soul's set and its time left; never a value
bin/secret manifest <soul>               # a soul's portable manifest (JSON, names only)
bin/secret read --soul <soul> <vault> <item> <field> # one field of a soul-set item (a value)
bin/secret item-json --soul <soul> <vault> <item>    # the item as `op item get --format json` prints it (values)
bin/secret <vault> <item> [field]        # the classic 1Password read (MCR_SOUL set: the soul's set first)
```

The narration hook (`bin/atomic-capture-hook`) blanks the output of `bin/secret
get`, `read`, `item-json` and the classic read, which print a value. It keeps the
output of `status`, `refresh`, `forget`, `contingency`, `migrate`, `prewarm`,
`warm`, `sets`, `manifest` and `help`, which print names and times only.

`status` speaks in time left: `expires in 42 min`, `expires in 6 min — inside the
refresh window, the next read refreshes`, `expired 3 min ago — refreshes on next
read`, `not cached by design: minted per call`. A failed refresh adds `last
refresh FAILED`.

GitHub tokens still come from `bin/gh-token`, which now keeps its cache in this
folder. `bin/secret` is the front door over it. `gh`, `git` (through
`bin/gh-app-git-credential`), `bin/submit`, `bin/pr-review`, `bin/dor-check` and
`bin/release` are unchanged callers.

### From Ruby on this Mac

```ruby
require "/Users/alex/projects/.agents/bin/lib/secret_cache"
SecretCache.status_lines            # the status, as lines
SecretCache.session_block           # what session start shows ("" when nothing is due)
```

To read a value, shell out to the fixed-path `bin/secret get <name>` and capture
stdout. Never open the files yourself: the guards (modes, git, sandbox) live in
the read path.

## When an entry expires, and when 1Password fails

**Expiry.** A GitHub token read inside its last ten minutes, or after it expired,
makes a bounded `op` read (14 s per attempt, retried once without the 1Password
cache daemon: `bin/lib/op_meter.rb`), mints a token, rewrites the cache, and
returns the fresh token. When the first `op` read fails, the second is skipped, so
a hung `op` reaches the contingency in seconds.

**A still-valid token survives a failed refresh.** When the refresh fails but the
cached token still has more than a minute left, `bin/gh-token` serves it and warns
on stderr. `bin/secret refresh` and `bin/secret prewarm` then say `served cached
fallback`, never `refreshed`, and `refresh` exits 1 because it did not get a fresh
token (`prewarm` still never fails). They tell the two apart by that warning, or by
an expiry that did not move forward.

**A hung or rate-limited 1Password backs every process off.** Those two failures
are account-wide, so `bin/gh-token` records them in the manifest and no process
reads `op` for the agent token until the window ends: one minute, doubling to
fifteen, cleared by the next successful mint. Inside it a still-valid token is
served; otherwise the refusal names the time and the one-call skip,
`MCR_OP_NO_BACKOFF=1 bin/gh-token`. `status` shows `1Password hung` or
`rate-limited` with the time. A failure one shell owns (its token not sourced)
does not back off the others, and the deployer never backs off.

**A watcher reads the cache only.** `bin/gh-token --cached-only` prints the shared
token or exits 3, and never reads 1Password; the dispatcher's harness probe uses it
whenever `op whoami` fails. The procedure over all of this is
[`credential-access.md`](credential-access.md).

**The contingency**, printed on stderr by any failed refresh, in order:

1. Use the other GitHub identity's cached token, if it is still valid and its scope
   covers the job. The agent identity opens, reviews and merges PRs. The deployer
   identity pushes `main` and deploys, and is never cached on disk. The printed
   line says what the other identity holds now.
2. Run the [`token-session`](token-session.md) SOP.
3. Ask Alex McRitchie to quit and reopen the 1Password app. That cleared the
   2026-10-27 hang. A hung read now says so in one line (`1Password is not
   answering`) and exits 75; a release can wait it out with
   `bin/release cycle --wait-for-1password[=MINUTES]` for the whole lane (it passes the
   flag to its prepare and ship), or `bin/release prepare|ship --wait-for-1password`
   for one act.
4. Report it as a blocker: name the entry, the failing `op` read, and the steps
   you tried.

## Session start and long runs

- **Session start** (`bin/session-insights`, the SessionStart hook) names every
  entry that has expired or expires within the hour, and any whose last refresh
  failed. It reads files only, spawns nothing, and says nothing when no entry is
  due. A GitHub token always expires within the hour, so expect one line saying
  it refreshes itself on read.
- **`bin/release prepare` and `bin/release ship`** run `bin/secret prewarm` first,
  so a GitHub token cannot expire mid-run. The prewarm never fails the run.

## Rotation: forget, so the old value never lingers

When a credential is rotated ([`credential-rotation`](../agents/steffon/sops/credential-rotation.md)
§4.4), run `bin/secret forget --source <1Password item>`. For a GitHub App key, for
example: `bin/secret forget --source github.mcritchie-agent`. The next read mints
from the new key. The same command drops every soul's copy of the item
(`bin/secret forget --source solana.mack.agent` clears `avi/`), so the next warm or
read fetches the new value.

## Soul secret sets

**Purpose.** Each soul has its own set of 1Password items. The set is warmed into
`<cache>/<soul>/` when the soul launches, and read from there. A stalled `op` then
stops nothing until an entry expires.

**Why (Alex McRitchie, 2026-11-09).** On the night of 2026-11-08 a release waited
about four hours on one live `op item get solana.mack.agent` inside the devnet
gauntlet. Task `soul-secret-sets`.

| Fact | Value |
|---|---|
| Config | `config/soul_secret_sets.yml`: one set per soul in `config/souls.yml` (a test holds every roster soul to a set, even an empty one). Each item names `item`, `vault`, `fields` (only these labels are kept on disk), `lifetime`, optional `refresh_window` (default a tenth of the lifetime) and `readers` |
| Folder | `<cache>/<soul>/`, `0700`; one `item.<item>.json` per item, `0600`, written by the same `O_EXCL \| O_NOFOLLOW` temp-file-then-rename path. The folder and file guards (mode, owner, symlink, git) apply |
| Admin vault | refused twice: at config load (a soul set that names an admin-vault item does not load) and at write (`AdminVaultRefused`) |
| Bound | every `op` call goes through `OpMeter.popen`, at most 20 s an attempt (`SoulSecrets::OP_DEADLINE_CAP`; 14 s by default). After a hang the warm pass stops calling `op` |
| Log | a cache answer is logged as `cache-hit`; a refused read as `soul-refused`; both in the read log (`bin/op-reads --by action`). Never a value |

**Today's sets.** Avi holds the two wallets the devnet gauntlet signs with
(`solana.mack.agent`, `solana.turf.agent`). Steffon holds `heroku.studio.agents`.
Every other soul's set is empty and lists the shared entries it uses
(`github.agent`, `harness-key`). Add an item from data: `bin/op-reads` names the
item behind every `bin/secret` read. Do not add one from a guess.

### The launch seam: the SubagentStart hook

`bin/install-agent-docs` wires a Claude Code `SubagentStart` hook,
`<projects>/.agents/bin/secret warm --hook`. Claude Code gives the hook the
subagent's `agent_type`, which is the soul's slug for every soul definition the
installer writes (`~/.claude/agents/<soul>.md`). When that soul's set has an item
that is not fresh, the hook starts `bin/secret warm <soul>` detached, in its own
process group. The hook prints nothing and always exits 0. A fresh set costs a few
file reads and no process.

Why this seam, and not the others:

- **SessionStart** runs once for the top-level session, before any soul is known,
  and its insights hook must spawn nothing.
- **`bin/agent-activity start`** is override-only since turn-driven narration
  (`bin/atomic-capture-hook` opens spans itself), so many launches never call it.
- **The role pages** are prose. A step an agent can skip is not a seam.
- **SubagentStart** fires on every soul launch, names the soul, and is installed
  by the same tooling as the other managed hooks.

A soul that runs outside Claude Code (Codex, a script) warms by hand:
`bin/secret warm <soul>`. A read warms the one item it needs on a miss, so a
missed warm costs one bounded read, not a failure.

### Reading, and the refusal

A soul names itself with `--soul <slug>` or `MCR_SOUL`. Then:

| The item is | The read |
|---|---|
| in this soul's set | the cache; inside the refresh window or after expiry, one bounded read written back. When that read fails, a copy that has not expired still serves, with a warning on stderr |
| in another soul's set only | **refused**, exit 4, logged as `soul-refused`. It never reaches 1Password |
| in no set | exit 3 (`not managed`): the classic read runs, unchanged |

With no `MCR_SOUL`, the classic `bin/secret <vault> <item>` read is unchanged.
Task `agent-op-reads-ratchet` closes that path later. Task
`secret-refresh-on-auth-failure` can use `bin/secret forget --source <item>`
and the read path above as its refresh.

**One Unix user, for now.** Every agent on this Mac runs as one Unix user, so the
per-soul folders are a policy line, not a security boundary: any process can open
any file. The refusal stops a soul's tooling from reading another soul's item by
accident, and logs every attempt. Ruling 2 (below) is what turns the line into a
boundary.

### The devnet gauntlet reads from the cache

`bin/release prepare` warms Avi's set before the gauntlet
(`warm_gauntlet_secrets!`, bounded at 90 s, never fatal). The driver's `PATH`
then starts with `bin/shims/op-cache` (`gauntlet_child_env`). That shim answers
`op item get <item> --vault <vault> --format json` for an item in Avi's set from
the cache, in the JSON shape `op` prints, so turf-monster's `KeyStore` reads it
unchanged. Any other `op` command, and an item no set names, go to the real `op`.
An `op` that stalls after the warm cannot stop the gauntlet.

### A portable unit (ruling 2)

Alex McRitchie plans to run different agents on different machines. A soul's set
moves as two things: its manifest and its own 1Password service account.

```bash
bin/secret manifest avi > avi.manifest.json        # names only, never a value
# on the new machine, with Avi's own service-account token:
OP_SERVICE_ACCOUNT_TOKEN_AVI=… bin/secret warm avi --manifest avi.manifest.json
```

Each set names `service_account.token_env` (`OP_SERVICE_ACCOUNT_TOKEN_<SOUL>`).
When that variable is set, the warm runs `op` with it. When it is not set, the
warm uses the machine's shared agent account and says so. No per-soul service
account is filed yet; filing one is Steffon's `credential-filing` work.

### The admin tier (ruling 1)

Admin-vault items are reached only through allowlisted purpose-built scripts. The
agent never holds the value.

- **The seam.** `SoulSecrets::Admin.read(item, field, cfg:)` runs inside the
  script's own process. It refuses (and logs `admin-refused`) unless the process's
  entry point (`$PROGRAM_NAME`, resolved) is one of `admin_tier.scripts` in the
  same tooling tree. It reads with `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`, never from a
  soul folder, bounded, and keeps the value in memory for `admin_tier.lifetime`
  (15 min). There is **no** `bin/secret` command that prints an admin value.
- **The allowlist** is the scripts that read an admin item today (`bin/release.rb`,
  `bin/gh-token`, `bin/heroku-token`, `bin/heroku-secret-set`,
  `bin/rotate-heroku-ci-key`). Moving each one onto `Admin.read` is later work.
  Adding a script is a reviewed config change.
- **The open choice: disk or memory.** The config says `storage: memory`, and a
  config that says `disk` does not load.
  - *Memory* (chosen): nothing is written; each script run pays one bounded read
    per item, and a hung `op` still stops that script.
  - *Disk* (0600, short lifetime): one read serves many runs. **The threat:**
    every process on this Mac runs as the same Unix user. A build lane, or a
    compromised gem or npm `postinstall` in a desk, can open a 0600 file
    directly and skip the allowlist, which only the read path enforces. So a disk
    tier turns "only allowlisted scripts" into "any process of this user".
  - *When disk becomes safe:* when the admin tier runs as its own Unix user, or
    its value sits in a keychain item whose access list names the script. Until
    then it stays in memory.

The existing rule stands beside it: nothing from an admin vault is ever written to
this folder.

## The legacy paths

Until 2026-10-27 the caches lived at `<projects>/.agents/github-tokens.json` and
`<projects>/.agents/harness-key.json`. The first write, or `bin/secret migrate`,
moves each one into the folder and leaves a **symlink** at the old path, so an
older installed copy of the tooling still reads the shared session. An older
`bin/gh-token` replaces that link with a file when it writes. Until every
installed copy is current, the read takes the freshest token from both files, and
the next write points the link back at the folder. A reject or a forget clears
both files. When no older copy is left (after the next production ship installs
the tooling), the links can be deleted.

## Tests

- `test/lib/secret_cache_test.rb` [unit]: refresh-window wording, expiry, the
  manifest, mode and git guards, the sandbox, legacy adoption, the session
  block, and the hardening: `served cached fallback` wording, `O_EXCL | O_NOFOLLOW`
  temp files, the owner and symlink check, the admin-vault refusal, `forget
  harness-key` under `MCR_SECRET_CACHE_DIR`, and the narration hook keeping
  metadata output.
- `test/lib/soul_secrets_test.rb` [unit]: the real config names a set for every
  roster soul; admin-vault items, missing fields and a disk admin tier are refused
  at load; warm writes `0600` files in a `0700` soul folder keeping only the named
  fields, reads nothing for a fresh set, uses the soul's own service account; a
  read after warm hits the cache while `op` hangs; another soul's read is refused
  and logged; the portable manifest warms alone; the hook; the admin allowlist and
  its memory-only read.
- `test/commands/soul_secrets_gauntlet_test.rb` [integration]: a release with `op`
  stubbed to hang after the warm still runs the gauntlet's driver (red without the
  shim: the step is killed at its deadline).
- `test/commands/secret_cli_test.rb` [integration]: a read inside the window
  refreshes; a read after expiry refreshes; a hung `op` reaches the contingency in
  seconds; a still-valid token survives; `forget` clears; no value appears in any
  output or metadata file; the classic read logs its item.

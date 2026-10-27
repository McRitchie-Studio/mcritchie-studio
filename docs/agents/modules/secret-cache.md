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
| Git | never inside a repository; the tooling refuses a folder with a `.git` at or above it |
| Backup | Time Machine may back it up; it is not excluded |
| Production | **Heroku dynos cannot read it.** It is a file on this Mac. An app in production keeps its credentials in its config vars |
| Override | `MCR_SECRET_CACHE_DIR` (tests); else `CLAUDE_PROJECTS_DIR/.secret-cache`; else `~/projects/.secret-cache` |
| Code | `bin/lib/secret_cache.rb` (`SecretCache`), `bin/lib/secret_cache_cli.rb`, `bin/secret`, `bin/gh-token` |

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
| `github.deployer` | GitHub App installation token, `github.mcritchie-admin` | 60 min · the last 10 min | **never**: minted per call, so a build lane cannot lift it off disk (`bin/gh-token` `CACHEABLE_IDENTITIES`) |
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
bin/secret forget github.agent           # drop one entry; the next read fetches it fresh
bin/secret forget --source <1Password item>       # drop every entry that item feeds (rotation)
bin/secret contingency github.agent      # the ordered steps for when op fails or hangs
bin/secret migrate                       # adopt the legacy .agents caches (idempotent)
bin/secret prewarm                       # before a long run: refresh tokens with under 45 min left
bin/secret <vault> <item> [field]        # the classic 1Password read
```

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
makes a bounded `op` read (20 s per attempt, retried once without the 1Password
cache daemon: `bin/lib/op_meter.rb`), mints a token, rewrites the cache, and
returns the fresh token. When the first `op` read fails, the second is skipped, so
a hung `op` reaches the contingency in seconds.

**A still-valid token survives a failed refresh.** When the refresh fails but the
cached token still has more than a minute left, `bin/gh-token` serves it and warns
on stderr.

**The contingency**, printed on stderr by any failed refresh, in order:

1. Use the other GitHub identity's cached token, if it is still valid and its scope
   covers the job. The agent identity opens, reviews and merges PRs. The deployer
   identity pushes `main` and deploys, and is never cached on disk. The printed
   line says what the other identity holds now.
2. Run the [`token-session`](token-session.md) SOP.
3. Ask Alex McRitchie to quit and reopen the 1Password app. That cleared the
   2026-10-27 hang.
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
from the new key.

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
  manifest, mode and git guards, the sandbox, legacy adoption, and the session
  block.
- `test/commands/secret_cli_test.rb` [integration]: a read inside the window
  refreshes; a read after expiry refreshes; a hung `op` reaches the contingency in
  seconds; a still-valid token survives; `forget` clears; no value appears in any
  output or metadata file; the classic read logs its item.

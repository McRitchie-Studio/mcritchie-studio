# Chrome Profiles

## Status: Active

This is Steffon's `chrome-profiles` SOP. It restores and maintains the operator's
Chrome avatar menu — **which Google accounts appear under "Other Chrome
Profiles", in what order, under what label** — from a roster kept in 1Password.

It is Steffon's because it is machine state on the operator's Mac, and because
the reason it exists at all is fresh-machine recovery.

## Why this is a registered act and not a note in someone's home directory

The arrangement used to live in two places, neither of them backed up: Chrome's
own `Local State` JSON inside `~/Library`, and a pair of hand-edited scripts in
`~/Applications`. A rebuilt Mac recreates neither. Worse, the four constraints
that make the thing work each cost a measured experiment to find, and every one
of them is invisible from the outside — a rebuilt machine looks like it is
working right up until you open the menu.

## The files

| What | Where |
|------|-------|
| **The roster (the durable record)** | 1Password document `chrome-profiles.mcritchie.agents`, in the agent lane's vault (`studio-agents` by default, resolved through `bin/lib/op_vaults.rb`) |
| The roster's shape, committed | `config/chrome_profiles.yml.example` |
| The tool | `bin/chrome-profiles` |
| The logic | `bin/lib/chrome_profiles.rb` |
| The launcher it generates | `~/Applications/Chrome (Ordered Profiles).app` |
| Chrome's own copy | `~/Library/Application Support/Google/Chrome/Local State` |

### Why the roster is in 1Password and not in this repo

**mcritchie-studio is a PUBLIC repository** — `gh api repos/McRitchie-Studio/mcritchie-studio`
returns `visibility: public`, and an unauthenticated GET of
`raw.githubusercontent.com` returns 200. The roster keys on **account email**,
and some of those accounts are family members' personal addresses rather than
business ones. Committing it published two addresses that had never appeared in
this repository before; it was caught in review on 2026-09-04, and a public
repo's history is scraped and mirrored faster than a later commit can retract it.

1Password is the right home for a second reason: it is already what a rebuilt Mac
restores from, so the burn-down guarantee this tool exists for is **kept**, not
traded away. The house rule this produced is
`docs/agents/modules/credentials.md` § Personal data in a public repo.

Read it, and update it after an edit:

```bash
op document get "chrome-profiles.mcritchie.agents" --vault "${MCR_OP_VAULT_AGENT:-studio-agents}"

# writing needs the admin lane — the day-to-day agent token is read-only
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
op document edit "chrome-profiles.mcritchie.agents" <file> --vault "${MCR_OP_VAULT_AGENT:-studio-agents}"
```

`bin/chrome-profiles` fetches it automatically when no `--config` is given, in
**one** metered read per invocation. The 1Password daily cap is account-wide and
shared with every other lane, so never put this in a loop or a poll.

## Prerequisites

| Needs | Why | Check |
|-------|-----|-------|
| **Ruby 3.x** | `bin/lib/chrome_profiles.rb` uses endless method definitions. Under macOS's own `/usr/bin/ruby` (2.6.10) the file does not parse and you get a bare `SyntaxError`, not a message — nothing can guard it, because it fails before any line runs. | `ruby -v` |
| **Google Chrome** | Nothing in this repo installs it — not `bin/ecosystem-build`, not the burn-down brew phase. Install with `brew install --cask google-chrome`. | `ls -d "/Applications/Google Chrome.app"` |
| **1Password CLI, signed in** | The roster lives there. | `op whoami` |
| **macOS** | Chrome's `Local State`, the Dock plist and `lsappinfo` are all macOS. | — |

## The invariant — read this before editing the roster

**The roster is keyed by ACCOUNT EMAIL. The profile directory is resolved
against the machine at run time and is never recorded.**

Chrome hands out `Default`, `Profile 7`, `Profile 14` in **sign-in order**. They
are an accident of history, they differ on every machine, and the numbering is
not even dense — signing into `team@mcritchie.studio` on 2026-09-04 produced
`Profile 14` on a Mac holding eleven profiles.

A directory-keyed roster restored onto a fresh Mac does not fail loudly. It
**renames the wrong profiles**, and the operator finds out by opening a menu.

## Four measured constraints

1. **Chrome must be fully QUIT before `Local State` is edited.** It holds the
   file in memory and rewrites it on exit, silently discarding any edit made
   while it was up. `bin/chrome-profiles apply` quits it for you.
2. **The custom order is IGNORED unless Chrome is launched with
   `--enable-features=ProfilesReordering`.** Chrome 152 prunes this flag from
   `chrome://flags` at startup — writing `profiles-reordering@1` into
   `browser.enabled_labs_experiments` does not survive, and this is specific to
   this flag (a control flag from the same table written the same way does
   survive). The command-line switch, carried by the wrapper app, is the only
   route. **Do not re-derive this.**
3. **The PARENTHESES cannot be removed.** Chrome renders each row as
   `<Google first name> (<profile name>)` and collapses to the name alone only
   when the two match. Blanking the cached GAIA name works for about 75 seconds,
   until Chrome refreshes account info and restores it. So a label must never
   repeat the word Chrome prepends — `bin/chrome-profiles` refuses one that does.
4. **The wrapper must force the native architecture.** A `.app` whose executable
   is a shell script does not reliably select the native slice of Chrome's
   universal binary. Measured 2026-09-04 on an M4 Pro: Chrome ran entirely as
   **x86_64 under Rosetta**, six renderers near 100% CPU, load average 11.6 —
   while the menu was perfect and every other check read green. The generated
   launch script runs `exec /usr/bin/arch -<host arch> …`, taken from `uname -m`
   rather than hardcoded — the same comparison `bin/chrome-profiles status` makes
   on the `arch:` line, so that an Intel Mac gets a launcher that starts at all.
   Do not remove it.

## Entry

Run from the McRitchie Studio primary checkout, or from any worktree — the
roster comes from 1Password, so the working copy you run from does not matter:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/chrome-profiles status
```

`status` is read-only and is the only command you should ever need to start
with. It exits **0** only when the roster resolves cleanly against this Mac with
no refusals, so a later step can gate on it.

## Act 1 — Change the menu

1. Pull the roster out of 1Password and edit it. List order is menu order;
   `label:` is **only** the text inside the parentheses.

   ```bash
   op document get "chrome-profiles.mcritchie.agents" --vault "${MCR_OP_VAULT_AGENT:-studio-agents}" > /tmp/roster.yml
   $EDITOR /tmp/roster.yml
   ```
2. If you introduced a new emoji, verify it — see **§ Verifying an emoji**.
3. Dry-run it against this Mac before it becomes the record. `--config` reads a
   FILE instead of the vault, and `status` writes nothing:

   ```bash
   bin/chrome-profiles status --config /tmp/roster.yml
   ```
4. Put it back — writing needs the admin lane:

   ```bash
   source ~/.zprofile.admin
   export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
   op document edit "chrome-profiles.mcritchie.agents" /tmp/roster.yml --vault "${MCR_OP_VAULT_AGENT:-studio-agents}"
   rm /tmp/roster.yml
   ```
5. `bin/chrome-profiles status` — now reading the vault, confirm the menu and
   the refusals.
6. `bin/chrome-profiles apply` — quits Chrome, backs up `Local State`, writes,
   relaunches via the wrapper, re-reads from disk, and reports whether the
   feature flag is live on the running process.

`apply` writes exactly three fields per profile — the order, the display name,
and `is_using_default_name`. Accounts, `gaia_id` and avatars are never touched.

## Act 2 — The menu went back to alphabetical

**The order is not lost.** A flagless Chrome ignores `profiles_order`; it never
deletes it. Measured across a reboot, a flagless session and a graceful quit —
the array came back intact every time. So this is always a LAUNCH problem, and
the repair writes nothing:

```bash
bin/chrome-profiles relaunch
```

The usual cause is the **Dock**: the pinned tile points at
`/Applications/Google Chrome.app`, which starts Chrome without the flag. Stop it
recurring with:

```bash
bin/chrome-profiles pin-dock
```

**Do not reach for `apply` here.** It rewrites Chrome's state to fix something
that was never broken.

One hole stays open by choice: the default browser handler is still
`com.google.chrome`, so if Chrome is closed and you click a link in another app,
macOS starts the stock Chrome without the flag. The wrapper is deliberately NOT
made the default browser — a shell-script app cannot receive the Apple Event
that carries the clicked URL, so it would launch Chrome and silently swallow the
link. Trading an occasionally-alphabetical menu for vanishing links is a bad
deal. `relaunch` covers it in ten seconds.

## Act 3 — The browser is slow

Check for Rosetta **first**, before extensions, tabs, or profiles:

```bash
lsappinfo info -only arch "$(pgrep -x 'Google Chrome' | head -1)"
#   "LSArchitecture"="arm64"   native
#   "LSArchitecture"="x86_64"  translated — the browser will crawl
```

`bin/chrome-profiles status` prints the same thing as an `arch:` line, and
`bin/chrome-profiles relaunch` treats translation as a reason to restart. If it
comes back translated even after a relaunch, the wrapper's launch script has
lost its `arch` switch — regenerate it with `bin/chrome-profiles install-wrapper`.

## Act 4 — Fresh Mac (the burn-down path)

Nothing here is restored by `bin/ecosystem-build`; Chrome's profile state is not
in any backup this repo controls.

```bash
# 0. Chrome itself. NOTHING in this repo installs it.
brew install --cask google-chrome

# 1. Sign into each account in Chrome, in any order. Directories do not matter.
#    Recover the account list from the vault copy of the roster:
op document get "chrome-profiles.mcritchie.agents" --vault "${MCR_OP_VAULT_AGENT:-studio-agents}"

# 2. Build the launcher that carries the feature flag (and the native arch).
bin/chrome-profiles install-wrapper

# 3. Point the Dock's Chrome tile at it, so a normal launch is the right launch.
#    PREREQUISITE: a Chrome tile must already be pinned to the Dock — this
#    repoints an existing tile and has nothing to repoint on a bare Dock. Open
#    Chrome once and keep it in the Dock first.
bin/chrome-profiles pin-dock

# 4. See what resolves.
bin/chrome-profiles status

# 5. Land it.
bin/chrome-profiles apply
```

Re-run steps 4-5 as you sign into the rest. When `status` exits 0 with no
"NOT SIGNED IN" block, the machine matches the roster.

### The two directions are NOT symmetrical, and only one of them is patient

- **A roster account you have not signed into yet is REPORTED and skipped.**
  That is the normal state halfway through a rebuild, and the rest still applies.
- **A profile on the MACHINE that the roster does not cover is a REFUSAL**, and
  it stops `apply` outright. This includes a profile **signed into no account at
  all** — a fresh `Person 1` that Chrome created for you, or one you signed out
  of — because a profile with no email cannot be keyed by a roster that keys on
  email. There is no flag to skip it and no placeholder that matches it. The
  only two exits are to **sign that profile in** or to **delete it in Chrome**
  (⋮ → Settings → the profile card → Delete).

That asymmetry is deliberate: it is the guard that stops a roster from silently
renaming or dropping a profile nobody declared. It is also the single most likely
thing to stop a fresh Mac mid-rebuild, so check for a stray empty profile first
when `apply` refuses and the accounts all look right.

To capture a machine that is ALREADY arranged the way you want — the reverse
direction, for seeding the roster:

```bash
bin/chrome-profiles adopt > /tmp/roster.yml   # prints a roster stanza
$EDITOR /tmp/roster.yml                       # add `profiles:` and the labels
bin/chrome-profiles status --config /tmp/roster.yml   # prove it before filing it

source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
op document create /tmp/roster.yml --title "chrome-profiles.mcritchie.agents" \
  --vault "${MCR_OP_VAULT_AGENT:-studio-agents}" --file-name chrome_profiles.yml
rm /tmp/roster.yml
```

## § Verifying an emoji

A codepoint absent from the system font renders as a **tofu box** in the menu,
and you find out by looking. Check before you commit a label:

```bash
bin/chrome-profiles emoji 🪎              # every non-ASCII codepoint in the string
bin/chrome-profiles emoji U+1FA8E U+1FA8B # or by codepoint, explicitly
```

It exits non-zero if anything is missing.

**Presence is not identity, and this only answers presence.** Ruby's and
Python's Unicode name tables on this Mac are Unicode 13, so they cannot even NAME
an Emoji 16/17 addition — `unicodedata` raises rather than returning the wrong
answer, which is at least honest. To learn WHICH glyph a codepoint draws, render
it and look:

```bash
python3 - <<'PY' > /tmp/emoji.html
cps = [0x1FA8E, 0x1FA8F, 0x1FA90]
print("<body style='font-size:96px'>" +
      " ".join(f"<span>{chr(c)}</span><small style='font-size:14px'>U+{c:04X}</small>"
               for c in cps))
PY
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --screenshot=/tmp/emoji.png --window-size=900,200 /tmp/emoji.html
open /tmp/emoji.png
```

Measured this way on 2026-09-04: U+1FA8E, U+1FA8F and U+1FA90 are chest, shovel
and ringed planet. The README's label for one of them was wrong, which is why
this section says render rather than trust a table.

## What this act is NOT

- **It is not part of `ecosystem-build`.** That script restores repos, secrets
  and stacks. This is the operator's browser, and it needs accounts signed in by
  hand first.
- **It never touches the task board, a branch, or a deploy.**
- **`apply` is not the fix for an alphabetical menu.** See Act 2.

## Verification

| Question | Command | Green |
|----------|---------|-------|
| Is the roster reachable? | `bin/chrome-profiles status` | `roster:` line reads `op://…` with the right count |
| Does the roster resolve? | `bin/chrome-profiles status` | exit 0, no REFUSALS block |
| Is the order live? | `bin/chrome-profiles status` | `chrome:` line reads `ProfilesReordering ACTIVE` |
| Is Chrome native? | `bin/chrome-profiles status` | `arch:` line reads `arm64 (native)` |
| Will the next launch be right? | `bin/chrome-profiles status` | `dock:` line names the wrapper |
| Is a new emoji real? | `bin/chrome-profiles emoji <char>` | exit 0 |

## Background — not needed to execute

- `docs/agents/system/house-burn-down.md` — the wider fresh-machine protocol.
- `bin/lib/chrome_profiles.rb`'s header carries the evidence behind each
  constraint above.

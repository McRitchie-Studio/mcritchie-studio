# Conductor Host
<!-- registry: turn a new Mac mini into the always-on conductor: dispatcher, build launcher, harness key, power -->

## Status: Active

This is Steffon's `conductor-host` SOP. It takes a new Mac mini from the box to
**the board sees it**: the agent dispatcher and the client build launcher running
under launchd on the mini, pinging the board every minute, with a harness key of
its own, and nothing of the kind left running on Alex's laptop.

Why a separate box: the laptop is the conductor today, and it sleeps. From
2026-10-21 to 2026-10-24 it slept on battery with the lid closed, and the
mailbox and the build launcher stopped with it. `caffeinate -is` cannot hold a
lid-closed sleep on battery
(audit `platform-audit-2026-10-24`, lane infra, "Machine" and D6). A desktop on
mains power with sleep turned off does not have that failure.

Written so a contractor can run it. Alex's hands are needed in three places,
marked **Alex** below; everything else is **Operator** (the person at the mini)
or **Script** (`bin/conductor-host-setup`, which the operator runs).

| Piece | Where |
|---|---|
| The script | `bin/conductor-host-setup` (`bin/lib/conductor_host.rb`) |
| Check mode | `bin/conductor-host-setup --check`: every item `done` or `MISSING`, exit 1 on a miss |
| The two services | [`agent-dispatcher`](agent-dispatcher.md) and [`client-build-launcher.md`](../../../system/client-build-launcher.md), both from `config/local_services.yml` |
| The toolchain | `bin/ecosystem-build` ([`ecosystem-build.md`](../../../system/ecosystem-build.md); manual fallback [`house-burn-down.md`](../../../system/house-burn-down.md)) |
| The harness key | `bin/harness-key` ([`agent-sessions-design.md`](../../../system/agent-sessions-design.md), section 3) |
| The hand-off marker | `~/.config/mcritchie/conductor-elsewhere`: while it exists, the services phase of `bin/ecosystem-build` installs neither service on that Mac |

## Roles

| Who | Does | Needs |
|---|---|---|
| **Alex** | (1) creates the mini's 1Password service account and pastes its token on the mini, and keeps the FileVault recovery key; (2) signs Claude Code in with his claude.ai account; (3) approves the mini's harness key on the board. Also runs the laptop half of the cutover | His 1Password, his claude.ai login, the board |
| **Operator** | Unboxes, cables, walks macOS setup, runs every command in this page on the mini | The mini, a temporary account password, this page. No secret: the operator never sees a token |
| **Script** | `pmset`, the directory layout, the hub clone, the Claude Code install, the two launchd agents (with `--take-over`), the harness-key request, and `--check` | Run by the operator, in Terminal on the mini |

Once the token is on the mini (step 5), anyone signed in as `alex` there can read
the `studio-agents` vault through `op`. That is why the operator's account
password is temporary and Alex replaces it in step 11.

Never a secret in chat, a ticket or a screenshot. The script prints none: each
item that needs one names the 1Password item instead.

## Decisions Alex owes before the box arrives (defaults stand on silence)

1. **Host name.** Default `conductor-mini`. It is how the board tells the mini's
   pings from the laptop's (`mac`), so it must differ from every other Mac.
2. **FileVault, or unattended restarts.** macOS turns automatic login off while
   FileVault is on, so the two cannot both be had.
   - **A (default): FileVault on.** After a power cut the mini boots to the
     unlock screen and waits. launchd agents are per-user (`gui/<uid>`), so
     nothing runs until a person types the password; the dispatcher's silent
     alert posts in `lobster-tank` after 5 minutes. A small UPS turns most
     outages into nothing.
   - **B: FileVault off, automatic login on.** The mini recovers from a power
     cut by itself, but its disk holds, unencrypted, the 1Password token in
     `~/.zprofile`, `AGENT_API_SECRET` in the hub's `.env`, the harness key and
     the Claude login.
3. **The admin (deployer) token stays on the laptop.** Production ships keep
   running from Alex's laptop; the mini never holds `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`.
   `--check` treats one in `~/.zprofile.admin` as a miss unless run with
   `--allow-admin-token`, which only Alex's say-so justifies.

## 1. Unbox and first boot (Operator)

1. Plug in Ethernet **before** power-on, and a UPS if there is one.
2. Setup Assistant:
   - Migration: **Not now**. This is a fresh build, not a copy of the laptop.
   - Apple Account: **Set up later**. The conductor needs none.
   - User account: an administrator, short name **`alex`**. Docs and the fixed
     tooling path assume `/Users/alex/projects`. Use a temporary password; Alex
     replaces it in step 11.
   - Location services, analytics, Siri, Screen Time: off.
   - FileVault: per decision 2. With A, turn it on and choose **Create a recovery
     key and do not use my iCloud account**. **Alex** keeps the recovery key in
     his own 1Password (not an agent vault).
3. System Settings:
   - **General > Sharing > Computer name** `conductor-mini`, then in Terminal:
     `sudo scutil --set HostName conductor-mini && sudo scutil --set LocalHostName conductor-mini`.
   - **General > Sharing**: Remote Login on and Screen Sharing on, for `alex` only,
     so Steffon and Alex can reach the box without a screen.
   - **Network**: Ethernet first in the service order; Wi-Fi off.
   - **Energy**: "Prevent automatic sleeping when the display is off" on, "Wake
     for network access" on, "Start up automatically after a power failure" on.
     The script sets the same with `pmset` (step 3) and `--check` reads it back.
   - **Lock Screen**: "Require password after screen saver begins or display is
     turned off" **Immediately**. The screen locks; the Mac does not sleep.
   - **General > Software Update > Automatic updates**: download only; leave
     "Install macOS updates" off. Under decision A a restart stops at the unlock
     screen, so updates are installed by a person who can type the password.

## 2. Toolchain prerequisites (Operator)

```bash
xcode-select --install          # a macOS dialog; wait for it to finish
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# then run the two `eval "$(/opt/homebrew/bin/brew shellenv)"` lines the installer prints
brew install ruby@3.3 && export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"
```

The script needs Ruby 3, and macOS ships Ruby 2.6, which cannot parse it. The
`export` lasts for this Terminal window; `bin/ecosystem-build` writes it into
`~/.zshrc` in step 4 (Phase 3).

## 3. Clone the hub and run the script (Operator + Script)

```bash
git clone https://github.com/McRitchie-Studio/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio
bin/conductor-host-setup
```

`sudo` asks for the account password once, for `pmset`. The script:

- sets `sudo pmset -c sleep 0 displaysleep 10 disksleep 0 womp 1 autorestart 1`;
- creates `~/Library/LaunchAgents`, `~/Library/Logs` and `~/.client-builds`;
- installs Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`) when missing;
- writes the hand-off marker, so nothing installs a second dispatcher on the mini
  before the cutover;
- requests the harness key once the board secret is in place (step 6).

It ends with the check. Misses at this point are expected; each prints its fix.

## 4. `bin/ecosystem-build`, first pass (Operator)

```bash
bin/ecosystem-build
```

Phases 1-3 install the Homebrew packages, Chrome, Postgres, Redis, Node, Rust,
Solana and Anchor, and the shell lines. It stops at Phase 4 because the
1Password token is not set yet. That stop is by design.

## 5. The 1Password token (Alex)

1. In 1Password (account `MWOV5OT5BRHATI4EGMN26C5DPA`): **Developer Tools >
   Service Accounts > Create**, name `conductor-mini`, **read on `studio-agents`
   only**. Not the admin vault. A token of its own means it can be revoked
   without touching the laptop's.
2. Copy the `ops_…` token. On the mini (in person, or over Screen Sharing with
   the shared clipboard):

   ```bash
   cd ~/projects/mcritchie-studio && bin/setup-1pass-token
   ```

   It reads the clipboard, writes `~/.zprofile` (mode 600) and verifies with
   `op vault list`. Then clear the clipboard.

All service accounts share the account's 1,000 reads a day
([`credentials.md`](../../../modules/credentials.md), "Who spent the quota");
the mini's two services read nothing from 1Password once the board secret is in
the `.env`.

## 6. `bin/ecosystem-build`, second pass, and the board secret (Operator)

```bash
source ~/.zprofile && bin/ecosystem-build
```

Phase 4 writes the local env files, Phase 5 clones the sibling repos, Phases 6-9
build and boot, and Phase 10 skips both services: Claude Code is not signed in
yet, and the hand-off marker holds them back in any case. The closing checklist
names what is owed. One line from it, which puts `AGENT_API_SECRET` (1Password
item `Agent API Secret`) in the hub's `.env` without showing it, is the
operator's; `bin/conductor-host-setup --check` prints the same line. Run it as
printed and never `cat` the file afterwards.

## 7. Claude Code sign-in (Alex)

```bash
claude auth login        # in a browser, with Alex's claude.ai account, not an API key
claude auth status       # authMethod must read claude.ai
```

Both services run headless `claude` on this subscription and refuse an API key.

## 8. The harness key (Operator, then Alex)

```bash
bin/conductor-host-setup                 # requests it now that the secret is in .env
# or by hand: bin/harness-key request --label conductor-mini
```

**Alex** approves the row `Harness key · conductor-mini` on
`https://mcritchie.studio/tasks` (the Approve tap, or the one-time code in his
reply). Then the operator collects it:

```bash
bin/harness-key collect --wait 600
bin/harness-key status                   # slug, machine and length; never the key
```

## 9. Chrome profiles: not needed

The dispatcher and the build launcher are headless: `claude -p` plus board API
calls, no browser. Phase 1 installs Chrome; leave it signed out. Run
[`chrome-profiles`](chrome-profiles.md) only if Alex starts working at the mini.

## 10. Cutover: one conductor, not two (Alex on the laptop, Operator on the mini)

Two dispatchers split the mailbox, and two launchers release each other's runs,
so the laptop gives the role up first and the mini takes it within a minute.

1. Pick a quiet minute: no build running (the app card reads no **Building**, or
   the laptop's `~/Library/Logs/client-build-launcher.log` shows none in flight).
   An uninstall sends a running build back in line, spending an attempt.
2. **Alex**, on the laptop (launchd changes need his hands; in a Claude session
   prefix the command with `!`):

   ```bash
   cd /Users/alex/projects/mcritchie-studio && bin/conductor-host-setup --hand-off-to conductor-mini
   ```

   It runs `bin/dispatcher uninstall` and `bin/client-build-launcher uninstall`
   and leaves the hand-off marker, so the laptop's next `bin/ecosystem-build`
   does not reinstall them.
3. **Operator**, on the mini, at once:

   ```bash
   bin/conductor-host-setup --take-over
   ```

   It removes the mini's marker and installs both services through the same
   restorer `bin/ecosystem-build` uses, which checks the sign-in and the `.env`
   secret first. The dispatcher's silent alert fires only after 5 minutes without
   a ping, so a prompt take-over raises none.

## 11. Smoke check (Operator, then Alex)

```bash
bin/conductor-host-setup --check   # every item done, ending with:
                                   #   done  The board sees one conductor: conductor-mini
bin/dispatcher status              # studio.mcritchie.agent-dispatcher: running (pid N)
bin/client-build-launcher status
bin/agent-presence                 # clear
tail -n 5 ~/Library/Logs/agent-dispatcher.log   # start dispatcher-conductor-mini-…
```

The board check reads `GET /api/v1/agent_dispatchers`: a live ping from the
mini's dispatcher and its launcher, and no live primary on any other host. The
same rows show on `/admin/agent_messages`. Then **Alex** posts
`@Avi what is building?` in `lobster-tank`; the log shows `claimed #N` and
`completed #N` within about a minute.

Last, **Alex** changes the account password the operator used (System Settings >
Users & Groups) and keeps it in his own 1Password. The operator's access ends
there.

## Caffeinate, and why it no longer keeps the box awake

Each service holds `caffeinate -is -w <its pid>` while it lives (`bin/dispatcher`,
`bin/client-build-launcher`). On the laptop that was the only guard, and `-s`
holds off sleep on AC power only, so a closed lid on battery slept anyway. On
the mini, `pmset sleep 0` on mains power is what keeps it awake; caffeinate stays
as a second guard if someone resets Energy settings. For a long unattended run
started by hand on any Mac, still wrap it: `caffeinate -is <command>`.

## What moved off the laptop

| Moved to the mini | Stays on the laptop |
|---|---|
| The agent dispatcher (`studio.mcritchie.agent-dispatcher`) | Alex's interactive Claude sessions and their desks |
| The client build launcher (`studio.mcritchie.client-build-launcher`) | The admin token and every production ship (`bin/release ship`) |
| | The laptop's own harness key, if it holds one |

The production ship's `install --if-changed` refresh does nothing on a Mac with
no plist installed, so ships from the laptop never reinstall the agents there.
The laptop could later become a registered standby
([`agent-dispatcher`](agent-dispatcher.md), "Standby on a second machine"); that
is a separate decision.

## Rollback

Back to the laptop, in the same order (give up first, take over second):

```bash
# on the mini
bin/conductor-host-setup --hand-off-to mac
# on the laptop (Alex)
rm -f ~/.config/mcritchie/conductor-elsewhere && bin/dispatcher install && bin/client-build-launcher install
```

**If the mini never took over, or is dead,** skip the mini line: the laptop line
alone resumes the laptop as conductor (Alex, with the `!` prefix in a Claude
session). A dead mini that comes back starts both services at login
(`RunAtLoad`), so run `bin/conductor-host-setup --hand-off-to mac` on it at once.

## After a power cut

The mini restarts by itself (`autorestart 1`). Under decision A it waits at the
unlock screen; the silent alert in `lobster-tank` says so after 5 minutes.
Someone types the password at the box, the services start at login (`RunAtLoad`),
and the recovery line posts. Under decision B it logs in and recovers alone.

## Done when

- `bin/conductor-host-setup --check` exits 0 on the mini, board item included.
- The laptop's `bin/dispatcher status` reads `not installed` and it holds
  `~/.config/mcritchie/conductor-elsewhere`.
- A `lobster-tank` message was answered from `conductor-mini`.
- `bin/harness-key status` on the mini names a key the board accepts.

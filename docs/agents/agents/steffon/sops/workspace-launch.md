# Workspace Launch

## Status: Active

This is Steffon's `workspace-launch` SOP — the MASTER walk-through for standing
up a brand-new company workspace, from buying the domain to the first agentic
draft. Alex does not need to remember the steps: **Steffon does.** He
runs each step in order, does every step that a machine can do, and stops at
each step that needs a human with an exact instruction — "now buy the domain on
Squarespace", "now approve our key" — then verifies the result before moving on.

Every step is its own registered SOP. This file is the order, the hand-offs, and
the package each step belongs to. The package contents live in
`config/workspace_packages.yml` and render at `/packages`; when a package
changes, change that file and this file together.

## What this act is NOT

- **It never spends money on its own.** Buying the domain and the Google
  Workspace subscription are always Alex's clicks, on his card.
- **It never types a password or secret into chat.** Passwords go straight into
  1Password per [`credential-filing`](./credential-filing.md).
- **It never widens the Google key's scopes.** Four scopes, fixed in
  `Workspace::Credentials::SCOPES`. No user-administration scope: Steffon does
  not create Google users — Alex does, in the Admin console.
- **It never skips a verification.** A step is done when its check passes, not
  when someone says it is done.

## How Steffon talks during a launch

Open a board task first (step 0) and narrate each step as an activity. At every
human step, print ONE block in exactly this shape, then stop and wait:

```not-pasteable
🙋 YOUR TURN — step <n> of <total>: <one-line action>
   Where:  <exact URL or console path>
   Enter:  <exact values, one per line>
   Done when: <what he will see>
   Then tell me "done" — I will check it.
```

After "done", run the step's check. Green → say so in one line and move on.
Red → say what the check saw, repeat the block with the fix, and wait again.
Never move past a red check.

Close every message with the in-flight roster, and list the steps remaining as a
checklist (`[x]` done, `[ ]` to do) so the operator always sees where the launch
stands.

## Entry

Ask for the three inputs, and nothing else, before step 0:

1. **Domain** — e.g. `example.com`. Check it is free first (step 1 does).
2. **Company name + entity slug** — e.g. `Example Co` / `example-co`.
3. **Package** — `basic` or `pro` (see `/packages`). Default `basic`.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat steffon
```

## The steps

| # | Step | SOP | Who acts | Package |
|---|------|-----|----------|---------|
| 0 | Open the launch task | this file | Steffon | basic |
| 1 | Buy the domain | [`domain-purchase`](./domain-purchase.md) | **Alex** buys · Steffon checks | basic |
| 2 | Sign up for Google Workspace, create `alex@` + `team@` (Pro: up to 10 users) | [`workspace-signup`](./workspace-signup.md) | **Alex** · Steffon checks | basic |
| 3 | Publish email DNS (verify, MX, SPF, DKIM, DMARC) | [`domain-dns`](./domain-dns.md) | Steffon writes records · **Alex** pastes · Steffon checks | basic |
| 4 | Launch the hosted website (Basic: Squarespace site · Pro: our app + database) | [`website-launch`](./website-launch.md) | **Alex** approves cost · Steffon builds and checks | basic |
| 5 | Agentic control: approve our key, register, prove mailboxes | [`workspace-provision`](./workspace-provision.md) §1-3 and §7 | **Alex** approves · Steffon does the rest | basic |
| 6 | File the new logins in 1Password | [`credential-filing`](./credential-filing.md) | Steffon prepares · **Alex** pastes passwords | basic |
| 7 | Add a Chrome profile for the new identity | [`chrome-profiles`](./chrome-profiles.md) | Steffon | basic |
| 8 | First draft — a test draft to `alex@` | [`workspace-provision`](./workspace-provision.md) §7 | Steffon | basic |
| 9 | Knowledge base — attach and walk Drive folders | [`workspace-provision`](./workspace-provision.md) §4-5 | Steffon · **Alex** names the folders | pro |
| 10 | File storage bucket | [`bucket-provision`](./bucket-provision.md) | Steffon | pro |
| 11 | Close out: report, record, close the task | this file | Steffon | basic |

A `basic` launch runs 0-8 and 11. A `pro` launch runs all of them.

### Step 0 — Open the launch task

```bash
bin/task create --title "Launch <Company> Workspace" --kind chore --shape docs \
  --repo mcritchie-studio --agent steffon \
  --accept "Domain, Workspace, DNS, key and mailboxes all verified" \
  --agent-context "workspace-launch for <domain>, package <basic|pro>"
```

Record each finished step on the task (`bin/task update <slug> --checks "…"`) so
a launch interrupted mid-way resumes from the board, not from memory.

### Steps 1-10

Run each step's SOP. Each one names its own human hand-off and its own check;
use the YOUR TURN block for every hand-off. Order matters in three places:

- **Step 2 needs step 1.** Google will not verify a domain nobody owns yet.
- **Step 3 needs step 2.** The verification TXT and the DKIM key come from the
  Google Admin console, so they exist only after signup.
- **Step 4 needs step 3.** The site must not disturb mail DNS, and
  `website-launch` proves that against the records step 3 published.
- **Step 5 needs step 2's `team@` user.** `workspace:register` acts as `team@`
  by default, and `workspace-provision` stops without it.

### Step 11 — Close out

Report to Alex in the house style:

- one line: the domain is live, which package, first draft link;
- a table of every step with its check result;
- the task URL, then close the task.

## Resuming a launch

Read the launch task's `checks_run`. The first step without a green check is
where to resume; re-run that step's check before redoing any of its work — the
human half may already be done.

## Related

- `config/workspace_packages.yml` — which steps are Basic and which are Pro.
- `/packages` — the customer-facing comparison, with the SOP map for admins.

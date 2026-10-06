# `credentials.md` passages cut at the 300-line limit — archived 2026-10-06

Frozen record, ARCHIVE-ONLY. When `promote-private-memory-to-docs` added rules to
`docs/agents/modules/credentials.md`, the page went over 300 lines, so the dated
history below moved here verbatim. The live rules are in that page.

---

Measured 2026-09-04 (`/tasks/chrome-profile-order-sop`): a config file keyed on
account email carried two family members' personal Gmail addresses into PR #1212.
Neither had ever appeared in the repository before. Review caught it; by then
the branch had been public for roughly forty minutes. The fix was to move the
whole file into 1Password and commit only a `.example` — see
`docs/agents/agents/steffon/sops/chrome-profiles.md`.

On 2026-08-30 an agent read a deployer
refusal as the never-provisioned case and put a repeated hand-mint chore on
Alex while a production deploy waited; the token had been on disk for two
days and sourcing it worked on the first try. Handing a deploy back to him
because a credential failed is the operator toil `AGENTS.md` forbids.

Both were measured on 2026-09-15, after a session read the SOP, measured the
admin token as absent, and reported production blocked. The token was present the
whole time, with the deployer item reading cleanly.

**Historical — the PAT era.** Until 2026-07-29 auth was a fine-grained PAT on
the `amcritchie` personal account (`agent.github`, wired via `gh auth login
--with-token` + `gh auth setup-git`). Fine-grained PATs cannot call the
check-runs API at all — which the CI gates read — so the PAT wiring is retired;
`agent.github` is deprecated pending deletion.

Since the 2026-07-29 org migration every repo lives under the **McRitchie-Studio**
org. (The live page now states this without the date.)

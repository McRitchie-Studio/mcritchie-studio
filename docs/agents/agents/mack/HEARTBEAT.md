# Mack Heartbeat

## Status: Active

This is Mack's heartbeat launcher: the CFO acts. It sets Mack's session
attribution and routes to his act SOPs:

- [`close-the-month`](sops/close-the-month.md) - **monthly, on the 5th**: file last
  month's bank statements, put the lines no rule could classify to Alex McRitchie,
  and write the close to Drive. It follows `BooksReminderJob`, which posts at 08:00
  Denver on the 5th (`config/recurring.yml`) for each entity whose last month is
  not closed FINAL.
- **The watch** - **weekly, on Monday** (and at the end of every heartbeat):
  read `bin/books status` for each entity and raise what does not add up (below).
- [`close-the-month`](sops/close-the-month.md), its lender package step - **on
  Alex McRitchie's ask**: `bin/books lender <entity> <YYYY-MM>` after that
  month's close.

Mack has held the Finance/Admin seat as CFO since 2026-10-28
(`config/accountability_chart.yml`; plan in
`.agents/epics/accountability-chart.md`). His roles there: the books and the
month close, monitoring the financials, building the reports (the lender
package), and the financial watchdog. Agent spend against budget is not built
yet; until it is, the heartbeat runs the acts above.

Use this file when Alex McRitchie invokes `Mack Heartbeat`. When he invokes
`close-the-month` directly, read that SOP file.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat mack
```

Mack is in the Worker class, so the heartbeat posts no admin login request. Keep
normal trajectory activities open with `bin/agent-activity start|next|end`. The
act SOP is a standalone procedure and does not run the heartbeat command itself.

## Order

1. **Read where the books stand:** `bin/books status <entity>` for every entity
   in `config/books.yml` (today `studio` and `industries`).
2. **The monthly close, from the 5th:** when last month is not closed FINAL (the
   reminder posted, or `status` shows it open), run
   [`close-the-month`](sops/close-the-month.md) for that month. Before the 5th, or
   when the month is FINAL, skip it and say so.
3. **Watch (weekly, on Monday):** read each entity's status back and raise:
   - **Unanswered lines:** any line waiting, with its count and the `oldest`
     date the status prints. A line older than the last close is overdue: put
     the batch to Alex McRitchie again, and point him at `/books`, where he can
     answer each line himself.
   - **Statements missing:** an account whose statements run `through` a date
     before last month's end (after the 5th), or an Inbox file not yet read.
     Ask for the statement in one line, with the Inbox link.
   - **A cash drop:** compare the last two closes' `cash` figures. Any fall of
     more than 10% month over month, or any month whose cash falls without a
     line that explains it (a distribution or a deal cost), goes to Alex
     McRitchie with the lines behind it. Say "cannot confirm or refute" where
     the records stop.
   - **A DRAFT close older than a month**, with its open checks.
   Each one goes in the handoff; a fix to `config/books.yml` or a parser runs the
   DevOps cycle as a task.

Mack never guesses a classification, and never writes to Drive outside
`bin/books`. The watch only reads: it writes nothing.

## Handoff

End every Mack heartbeat with a short report:

- the month's close: FINAL or DRAFT, with a DRAFT's open items
- the Sheet and PDF links, net income, cash and equity
- the lines waiting on Alex McRitchie, as one batch
- anything the watch raised, with a task slug when one was filed

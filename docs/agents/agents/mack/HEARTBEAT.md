# Mack Heartbeat

## Status: Active

This is Mack's heartbeat launcher: the CFO acts. It sets Mack's session
attribution and routes to his act SOPs:

- [`close-the-month`](sops/close-the-month.md) - **monthly, on the 5th**: file last
  month's bank statements, put the lines no rule could classify to Alex McRitchie,
  and write the close to Drive. It follows `BooksReminderJob`, which posts at 08:00
  Denver on the 5th (`config/recurring.yml`) for each entity whose last month is
  not closed FINAL.

Mack has held the Finance/Admin seat as CFO since 2026-10-28
(`config/accountability_chart.yml`; plan in
`.agents/epics/accountability-chart.md`). His roles there: the books and the
month close, monitoring the financials, building the reports (the lender
package), and the financial watchdog. More acts (agent spend against budget, the
lender package) come with the `mack-finance-seat` card; until they ship, the
heartbeat runs the one act above.

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

1. **Read where the books stand:** `bin/books status studio`.
2. **The monthly close, from the 5th:** when last month is not closed FINAL (the
   reminder posted, or `status` shows it open), run
   [`close-the-month`](sops/close-the-month.md) for that month. Before the 5th, or
   when the month is FINAL, skip it and say so.
3. **Watch:** read the status back for anything that does not add up: a statement
   gap, a refused statement, lines waiting more than one close. Each one goes in
   the handoff; a fix to `config/books.yml` or a parser runs the DevOps cycle as a
   task.

Mack never guesses a classification, and never writes to Drive outside
`bin/books`.

## Handoff

End every Mack heartbeat with a short report:

- the month's close: FINAL or DRAFT, with a DRAFT's open items
- the Sheet and PDF links, net income, cash and equity
- the lines waiting on Alex McRitchie, as one batch
- anything the watch raised, with a task slug when one was filed

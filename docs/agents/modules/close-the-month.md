# Close the Month: an entity's books, from bank statements to a Sheet and PDF in Drive
<!-- registry: file last month's bank statements, answer the lines no rule could classify, write the close to Drive -->

## Status: Active

Alex McRitchie asked for it on 2026-10-27: "a close the month SOP we can run with
generates fresh artifacts to Google Drive for book keeping." He chose the shape the
same day. Statements arrive through a Drive Inbox folder. Each close writes a live
Google Sheet plus its PDF. Two entities are configured, each with its own books
folder in its own domain's Drive: `studio` (McRitchie Studio LLC, in
`team@mcritchie.studio`'s Drive) and `industries` (McRitchie Industries LLC, in
`team@mcritchie.industries`'s Drive, added 2026-10-28). The command runs on demand,
with a reminder on the 5th.

This SOP stands alone; every command is inline. Any agent may run it. Alex McRitchie
answers what the bank statement cannot: what a wire was for, or whether a deposit
was revenue. **The agent never guesses a classification.**

## The split

| Deterministic: the hub (`bin/books`) | Agentic: you |
|---|---|
| Reading each statement PDF and checking its lines against the bank's own totals | Asking Alex McRitchie about each line no rule could classify, one batch per close |
| The rules in `config/books.yml` that classify interest, fees, own-account transfers and known payees | Writing his answer down with `bin/books classify`, citing him and the date |
| The ledger (`book_statements`, `book_entries`), the checks, and the workbook's formulas | Deciding when a new payee deserves a rule (a `config/books.yml` diff runs the DevOps cycle) |
| Writing `Closes/<YYYY-MM>/` in Drive, and updating the same two files on every re-run | Reading the close's checks back to him, and handing him the links |

## Where things live

- **Drive.** The books folder, `McRitchie Studio Books/`, holds:
  - `Inbox/`: where he drops PDFs;
  - `Statements/<year>/`: the hub's filed copies;
  - `Closes/<YYYY-MM>/`: a Sheet and a PDF.

  The folder lives in `team@mcritchie.studio`'s Drive. That is the domain's workspace
  subject, the only address the hub may act as in Drive. The root is shared with
  `alex@mcritchie.studio` as a writer, so it appears in his Drive under "Shared with
  me". `bin/books setup studio` creates the tree, shares it, and prints the links.
  It is safe to re-run.

  Each entity has its own folder of the same shape. McRitchie Industries' is
  `McRitchie Industries Books/`, in `team@mcritchie.industries`'s Drive, shared with
  the same `alex@mcritchie.studio`; `bin/books setup industries` creates it.

  **Never create these folders by hand.** Under the `drive.file` scope, the hub can
  write only into folders it made itself. **Never point `drive_subject` at a
  mailbox** such as `alex@`: a mailbox opens mail, never Drive, and every
  `bin/books` call would be refused.
- **The ledger.** Hub production tables `book_statements`, `book_entries` and
  `book_closes`. The Sheet is generated from them. An edit made in the Sheet is
  lost on the next run, so record every change with `classify`.
- **The rules and chart of accounts.** `config/books.yml`.
- **Code.** `app/services/books/`, `bin/books`, and the reminder
  `BooksReminderJob` (08:00 Denver on the 5th, `config/recurring.yml`).

## How the books are kept

- **Cash basis.** A line is booked on the date the bank posted it.
- **Member contributions and distributions are equity, never P&L.** Alex owns
  Studio personally, as a single-member LLC. Money he puts in or takes out is not
  income, and it is not an expense. Never book a draw as an expense to improve a
  P&L: the lender reads these statements.
- **Acquisition costs paid from Studio are distributions** (purpose `Acquisition
  costs`). The deal belongs to McRitchie Industries, not to Studio.
- **A purpose groups distributions on the balance sheet.** Reuse the existing
  purposes: `Owner draws`, `Acquisition costs`, `Equity injection to Industries`.
- **Unanswered lines stay unclassified.** The close is then a DRAFT. Its balance
  sheet still balances, because they sit in equity as "Unclassified lines (to confirm)".

## Run it

The command runs from the hub (`/Users/alex/projects/mcritchie-studio`, or any desk).
Each call is one `heroku run`, about 20 seconds. `--by` is required on every write.

### 1. See where the books stand

```bash
bin/books status studio
```

It lists each account's statements and the last day they cover, any Inbox PDFs
not yet read, how many lines wait for an answer, and every close so far.

### 2. Get the statements in

If last month's statements are not in the Inbox, ask Alex McRitchie for them in one
line: "Drop September's Huntington statements (money market ···9501 and checking
···0881) into the Inbox: <link from setup>." He downloads them from Huntington
Business Online. When he hands you files in the session instead, send them
directly:

```bash
bin/books intake studio --by <you> [--file ~/Downloads/<statement>.pdf ...]
```

Without `--file`, it reads the Inbox. For each PDF it prints FILED, ALREADY
FILED or REFUSED. **A REFUSED statement is never filed partly.** The usual causes:
- The lines do not add up to the bank's totals. The parser missed a line, or the
  layout changed. Fix `Books::HuntingtonParser` with a task; never classify around it.
- The account is not in `config/books.yml`. Ask Alex McRitchie whether it is a
  new account of this entity, then add it with a task.

Read every warning. "opens at X, but … closed at Y" means a statement is missing
in between.

### 3. Answer the lines no rule could classify

`intake` ends with the list, and `bin/books unclassified studio` prints it again.
Put the whole batch to Alex McRitchie at once, each line as date, account, amount
and description, with your suggested reading only where the records support it.
Then record each answer:

```bash
bin/books classify studio 41 42 --category member_distribution --purpose "Acquisition costs" \
  --note "Alex McRitchie 2026-10-21: $3,000 broker retainer, $4,000 lender deal costs" --by <you>
```

The categories are the keys under `categories:` in `config/books.yml`. Use
`--category none` to undo an answer. When the same payee will recur every month,
propose a rule; adding it is a `config/books.yml` diff, so it runs the DevOps cycle.

### 4. Close the month

```bash
bin/books close studio 2026-10 --by <you>
```

It prints FINAL or DRAFT, the Sheet and PDF links, year-to-date net income, cash
and equity, and each check. A close is FINAL only when:
- every open account has a statement covering the month;
- each account's statements chain with no gap;
- every statement reconciles;
- every line is classified.

Re-run it as often as you like. It updates the same two files, and Drive keeps
their revision history, so a link Alex has shared stays good. If a file was
deleted, the close makes a new one and says that its link changed.

The Sheet's tabs:
- **Notes:** status and reasons, the checks, waiting lines, and the statements.
- **P&L:** by month for the year.
- **Balance Sheet:** cash per account against the statement, and equity by source.
- **Equity:** the year's rollforward, tied to the balance sheet.
- **Ledger:** every line since the books began.

Every figure is a formula over the Ledger. The "must be 0" checks on Balance Sheet
and Equity have to read zero.

### 5. Hand back

Give Alex McRitchie:
- the status, with a DRAFT's open items as a short list;
- the Sheet and PDF links;
- net income, cash and equity;
- anything a warning raised.

If the close is for a lender, attach the PDF yourself only when he asks. The links
are private to his Drive.

## The reminder

On the 5th at 08:00 Denver, `BooksReminderJob` posts to the `books_reminder` report
destination, once for each entity whose last month is not closed FINAL. The post
lists each open account's statement (in or missing), the lines waiting, and the
Inbox link. Alex McRitchie picks its Discord channel at `/admin/report_destinations`.
Until he does, the delivery is recorded as not configured, and nothing posts.

## Adding an entity

Add an entry under `entities:` in `config/books.yml`. It needs:
- `name`;
- `drive_subject` (an ACTIVE workspace account);
- `drive_root`;
- `accounts`, each with its last four digits and the date its first statement starts;
- `rules`.

That is a config diff, so it runs the DevOps cycle. Then run
`bin/books setup <entity>`. A bank other than Huntington needs its own parser
beside `Books::HuntingtonParser`. Commercial Welding keeps its own books and is
not run through this.

## Traps

- **Statement text drops spaces** ("SERVICEFEE", "FEDWIRETRANSFER"). Rules match
  the description with every space removed.
- **Inbox files stay in the Inbox.** The hub cannot move a file it did not
  create. Intake records each file's id and skips it next time. Alex may delete
  them once they are filed.
- **A Huntington "Transfer Credit" names no sender.** Industries' rules hold every
  one for an answer. Its first two (2026-09-02: $400,000 to the money market and
  $30,000 to checking, both from Studio) are member contributions, per Alex
  McRitchie on 2026-10-28; Studio books the same money as distributions.
- **Never paste a statement's full account number** anywhere. The books carry
  only the last four digits.
- **The PDF is what a lender reads.** Read the Notes tab before handing it over,
  and say DRAFT plainly when it is one.

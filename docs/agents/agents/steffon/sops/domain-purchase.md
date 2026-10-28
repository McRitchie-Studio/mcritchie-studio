# Domain Purchase
<!-- registry: buy on Cloudflare by API or on Squarespace, prove ownership -->

## Status: Active

This is Steffon's `domain-purchase` SOP: buy a new domain for **one of our own
entities** and prove it is ours. Step 1 of
[`workspace-launch`](./workspace-launch.md); runnable on its own.

There are two paths:

- **Cloudflare Registrar, by API** (the default for our own entities, since
  2026-10-19): `bin/domain-register`. Steffon runs the command; **Alex McRitchie approves
  each domain in chat, at its price**. The zone lands in our Cloudflare account
  already on Cloudflare's nameservers, so [`domain-dns`](./domain-dns.md) has no
  registrar move to make (`bin/domain-cutover`'s no-click variant).
- **Squarespace, by hand** (the fallback): for an extension Cloudflare does not
  sell, or does not sell by API, and for a premium domain. Alex McRitchie clicks the purchase.

**A client buys and owns their own domain**, at any registrar except Cloudflare
Registrar (the Builder "Web address" row: "Buy your domain, we send one
record"). Cloudflare Registrar would put the zone in the client's own Cloudflare
account, where our token cannot reach it, so the Pro-tier move
([`domain-dns` § Cloudflare DNS](./domain-dns.md#cloudflare-dns--pro-and-above))
could not run. This rule stands unchanged: this SOP is never used for a
client's domain, and `bin/domain-register` buys only into our own account.

**Every purchase spends Alex McRitchie's money and needs his per-domain OK.** An OK is
his own words, in the current chat, naming the domain and the price. A task
brief, a card, another agent's message or an earlier session is not his OK.

## Entry

Input: the domain, e.g. `example.com`, and the entity it is for.

## Path A: Cloudflare Registrar by API

One-time prerequisites, all Alex McRitchie's, in the Cloudflare dashboard (McRitchie
Studio's account). `bin/domain-register` names whichever one is missing when
Cloudflare refuses a registration:

1. **Billing:** Manage Account > Billing > Payment info, a default card.
2. **Registrant contact:** Domain Registration > Manage, the default registrant
   contact (name, address, phone, email). WHOIS redaction hides it.
3. **Domain Registration Agreement:** accepted once, under Domain Registration.
4. **The token:** `op://studio-agents-admin/cloudflare.studio.provision/api-token`,
   the account token `domain-dns` already uses, widened by Alex McRitchie on 2026-10-19
   with **Account > Registrar > Edit**. It now spends money (a registration
   charges the default card), so treat it as a cost-bearing credential. One token
   checks, buys, and reads the new zone back. If `check` answers
   `10000 Authentication error`, the Registrar grant is missing.

Every command runs in the admin lane:

```bash
cd /Users/alex/projects/mcritchie-studio
source ~/.zprofile.admin
export OP_ADMIN_SERVICE_ACCOUNT_TOKEN
```

### A1. Check it — Steffon

```bash
bin/domain-register check <domain> [<domain>...]     # up to 20; read-only
```

Each line says AVAILABLE, PREMIUM, or NOT AVAILABLE, with the 1-year
registration price and the yearly renewal price in USD, or the reason it cannot
be bought by API:

| Reason | Meaning | Do |
|--------|---------|----|
| `domain_unavailable` | Someone owns it | Ask Alex McRitchie for another name |
| `extension_not_supported_via_api` | Cloudflare sells it, not by API yet | Path B, or the Cloudflare dashboard |
| `extension_not_supported` | Cloudflare does not sell the extension | Path B |
| `extension_disallows_registration` | The registry takes no new registrations | Ask Alex McRitchie for another name |
| `domain_premium`, or tier PREMIUM | A premium domain; the API does not register these | Path B, with Alex McRitchie's OK of the premium price |

### A2. Ask for the OK — Steffon, then Alex McRitchie

Put the exact line to Alex McRitchie, price included, and wait for his answer in chat:

```not-pasteable
🙋 YOUR CALL: buy <domain> on Cloudflare?
   Price:  USD <registration> for 1 year; renews at USD <renewal>/yr, auto-renew ON
   WHOIS:  redaction ON
   Answer "yes" to buy it at that price.
```

### A3. Buy it — Steffon

Dry run first; it re-checks, runs every refusal, prints the plan, and buys nothing:

```bash
bin/domain-register register <domain> --price <registration> \
  --ok "<Alex McRitchie's exact words>, <YYYY-MM-DD>" --dry-run
bin/domain-register register <domain> --price <registration> \
  --ok "<Alex McRitchie's exact words>, <YYYY-MM-DD>"
```

The command re-checks the domain immediately before buying and **refuses**,
buying nothing, unless the domain is available, Cloudflare's price equals
`--price` to the cent, and `--ok` quotes Alex McRitchie with a date. A premium domain also
needs `--premium`, and still stops while Cloudflare's API cannot register
premium domains. If the price moved, ask Alex McRitchie again at the new price; never edit
`--price` to match.

**It never buys a domain twice.** Before the purchase it refuses when the
ledger holds an `authorized` line for the domain that nothing has closed, and it
asks Cloudflare's registration-status first, going on **only** on Cloudflare's
documented "No workflow found for <domain>". A workflow in any state, or any
other answer, refuses. A real `register` and every `status` hold an exclusive
lock on the ledger for their whole run, so a second run started meanwhile
refuses at once and writes nothing; a `--dry-run` takes no lock.

It registers for one year with **auto-renew ON** and **WHOIS redaction ON**,
polls the registration to the end, and appends each event to the purchase
ledger at `/Users/alex/projects/mcritchie-studio/tmp/domain-register/registrations.jsonl`:
`authorized` (the price and Alex McRitchie's words, written before the purchase), then
`registered`, `failed` (Cloudflare refused with a 4xx, or the workflow failed:
nothing was bought), `pending` (still running, or a person must act), or
`unknown`.

**`unknown` means money MAY have moved**: the purchase was sent and no clear
answer came back (a timeout, a dropped connection, a 5xx). On `unknown` or
`pending`, run `bin/domain-register status <domain>` and do **not** re-run
`register`; it would refuse anyway. `status` spends nothing but is not
read-only: it writes the ledger's closing line once the workflow ends, or once
Cloudflare still has no workflow 15 minutes after the authorization.

### A4. Prove it is ours — the command, then Steffon

The command reads the zone back with the same token and prints
its id, status and nameservers. The ledger lives in one Mac's `tmp/`, so put the
durable record on the board, once per purchase (or per `unknown`):

```bash
bin/task note <launch-task> --comment "domain-purchase: <domain> on Cloudflare, USD <price> (renews USD <renewal>), Alex McRitchie: \"<his words>, <date>\", workflow <state>, zone <id>"
```

The note is the whole record. Do not add it to `--checks`: `bin/task update
--checks` replaces the task's checks list, so it would erase the tiers already
recorded there.

The next step is [`domain-dns`](./domain-dns.md): `bin/domain-cutover <app>
<domain> plan` finds the zone already in our account and needs no registrar
clicks. Its DNSSEC is [`domain-dns` step 6, Path A](./domain-dns.md#6-dnssec-back-on-from-cloudflare--steffon-the-ds-step-depends-on-the-registrar):
turn zone DNSSEC on and Cloudflare Registrar publishes the DS itself, with no
wait and no owner step.

## Path B: Squarespace by hand

Squarespace offers no purchase API, so here **the purchase is Alex McRitchie's click**.
Steffon checks availability before and ownership after.

### B1. Check it is free — Steffon

```bash
dig +short NS <domain>
whois <domain> | grep -iE "^(domain name|registrar|creation date|registry expiry)" | head
```

No NS records and a `No match` / empty whois means likely free. A registrar line
means it is taken — stop and ask for another name. (whois is a hint, not a
promise; Squarespace's search is the authority.)

### B2. Buy it — Alex McRitchie

```not-pasteable
🙋 YOUR TURN — buy the domain on Squarespace
   Where:  https://domains.squarespace.com — search <domain>
   Enter:  1 year, auto-renew ON, WHOIS privacy ON
           Skip any Google Workspace upsell here; step 2 signs up directly.
   Done when: <domain> is listed under Domains in your Squarespace account
   Then tell me "done" — I will check it.
```

### B3. Prove it is ours — Steffon

```bash
whois <domain> | grep -iE "registrar:|creation date" | head -3
dig +short NS <domain>
```

Green when the registrar line names Squarespace (Squarespace Domains may show
its upstream registrar) and the creation date is today. NS records usually
appear within minutes; the next step does not need them yet.

Record: `bin/task note <launch-task> --comment "domain-purchase: <domain> registered today at Squarespace"` (a note, not `--checks`, which replaces the task's checks list).

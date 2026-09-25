# Domain Purchase

## Status: Active

This is Steffon's `domain-purchase` SOP: buy a new domain on Squarespace
Domains and prove it is ours. Step 1 of
[`workspace-launch`](./workspace-launch.md); runnable on its own.

**The purchase is always Alex's click.** It spends money on his card,
and Squarespace offers no purchase API. Steffon checks availability before and
ownership after.

## Entry

Input: the domain, e.g. `example.com`.

## 1. Check it is free — Steffon

```bash
dig +short NS <domain>
whois <domain> | grep -iE "^(domain name|registrar|creation date|registry expiry)" | head
```

No NS records and a `No match` / empty whois means likely free. A registrar line
means it is taken — stop and ask for another name. (whois is a hint, not a
promise; Squarespace's search is the authority.)

## 2. Buy it — Alex

```not-pasteable
🙋 YOUR TURN — buy the domain on Squarespace
   Where:  https://domains.squarespace.com — search <domain>
   Enter:  1 year, auto-renew ON, WHOIS privacy ON
           Skip any Google Workspace upsell here; step 2 signs up directly.
   Done when: <domain> is listed under Domains in your Squarespace account
   Then tell me "done" — I will check it.
```

## 3. Prove it is ours — Steffon

```bash
whois <domain> | grep -iE "registrar:|creation date" | head -3
dig +short NS <domain>
```

Green when the registrar line names Squarespace (Squarespace Domains may show
its upstream registrar) and the creation date is today. NS records usually
appear within minutes; the next step does not need them yet.

Record: `bin/task update <launch-task> --checks "[control] domain-purchase: <domain> registered today at Squarespace"`.

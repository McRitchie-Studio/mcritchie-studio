# Website Launch

## Status: Active

This is Steffon's `website-launch` SOP: put a hosted website on a new domain.
It delivers the **Hosted domain** row on `/packages`, and it is a step of
[`workspace-launch`](./workspace-launch.md); runnable on its own.

**To the customer it is always "an app we host."** What runs behind it depends
on the package, and the customer never needs to know which:

| Package | What the customer gets | What runs it |
|---------|------------------------|--------------|
| Basic | 1 domain · standard hosting | A **Squarespace site** on the domain, in Alex's Squarespace account |
| Pro | 1 domain · more power + database space | **Our app**: a standalone Rails app on Heroku with its own Postgres database |

Decided by Alex, 2026-09-24: "App we host. Behind the scenes it could
be Squarespace."

## What this act is NOT

- **It never spends money on its own.** A Squarespace site plan and a Heroku
  app plus database are recurring costs, so each is Alex's approval.
- **It never touches the mail records.** A website needs only `@`/`www` web
  records. MX, SPF, DKIM and DMARC from [`domain-dns`](./domain-dns.md) stay
  exactly as they are, and the last step re-checks them.
- **It never builds the customer's app features.** Pro stands up the empty,
  hosted app; anything built inside it is ordinary task-board work.

## Entry

Input: the domain (already ours and on Squarespace, via
[`domain-purchase`](./domain-purchase.md)), the company name, and the package.
Mail DNS ([`domain-dns`](./domain-dns.md)) should be green first, so the last step can
prove the site did not disturb it.

## Basic — a Squarespace site behind the scenes

### 1. Create the site — Alex

```not-pasteable
🙋 YOUR TURN — create the website on Squarespace
   Where:  https://account.squarespace.com → Websites → Create website
   Enter:  any starter template; site title: <Company>
           Settings → Domains → use <domain> (already in this account)
           Choose the site plan when prompted
   Done when: https://<domain> shows the Squarespace site
   Then tell me "done".
```

Because the domain already lives in the same Squarespace account, connecting it
adds the web records itself; nothing is pasted by hand.

### 2. Check it — Steffon

```bash
curl -sS -o /dev/null -w "%{http_code} %{url_effective}\n" -L https://<domain>
curl -sS -o /dev/null -w "%{http_code}\n" -L https://www.<domain>
```

Green when both answer `200` over HTTPS. Then run the last step.

## Pro — our hosted app with a database

### 1. Approve the cost — Alex

```not-pasteable
🙋 YOUR TURN — approve the hosting cost
   What:   one Heroku app + one Heroku Postgres database for <Company>
   Cost:   <the plans Steffon names, with their monthly price>
   Then tell me "approved".
```

### 2. Create and deploy the app — Steffon

Follow the **standalone / client app** tier of
[`../../../system/new-app-onboarding-sop.md`](../../../system/new-app-onboarding-sop.md)
for the repo, runtime and branch decisions, built from the BASE template in
[`../../../system/app-templates.md`](../../../system/app-templates.md). Then:

```bash
heroku create <app-name>
heroku addons:create heroku-postgresql:<plan> -a <app-name>
heroku domains:add www.<domain> -a <app-name>      # prints the DNS target
heroku certs:auto:enable -a <app-name>
```

Deploy the app, and confirm `https://<app-name>.herokuapp.com/up` answers `200`
before touching DNS. Then run step 3 and step 4, then the last step.

### 3. Point the domain at it — Alex

Squarespace DNS does offer an ALIAS record at `@`, but only with DNSSEC switched
off (Squarespace Help, "DNS records for web hosting"). This SOP leaves DNSSEC
alone instead: `www` carries the site and the bare domain forwards to it.

```not-pasteable
🙋 YOUR TURN — point the domain at our app
   Where:  https://account.squarespace.com/domains → <domain> → DNS
   Enter:  Custom record: Host www · Type CNAME · Value <DNS target from Heroku>
           Remove any other www record (a Squarespace site one, if present)
           Domain forwarding: <domain> → https://www.<domain> (301)
   Done when: both show in the domain's settings
   Then tell me "done".
```

### 4. Check it — Steffon

```bash
dig +short CNAME www.<domain>                              # the Heroku DNS target
curl -sS -o /dev/null -w "%{http_code}\n" https://www.<domain>/up
curl -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" http://<domain>
```

Green when `www` resolves to the Heroku target, `/up` answers `200` over
HTTPS (Heroku's certificate can take several minutes to issue), and the bare
domain redirects to `https://www.<domain>`.

## Last step — mail is untouched (both packages)

```bash
dig +short MX <domain>                  # still 1 smtp.google.com.
dig +short TXT <domain> | grep spf1     # still the one SPF record
```

Green when both match what [`domain-dns`](./domain-dns.md) published. If
either changed, restore it before closing the step — a site that works while
the company's email stops arriving is a failed launch.

Record: `bin/task update <launch-task> --checks "[control] website-launch: https://<domain> 200, mail DNS unchanged"`.

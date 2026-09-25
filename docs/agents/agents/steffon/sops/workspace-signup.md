# Workspace Signup

## Status: Active

This is Steffon's `workspace-signup` SOP: create the Google Workspace for a new
domain, with `alex@` as its super-admin and a `team@` user. Step 2 of
[`workspace-launch`](./workspace-launch.md); runnable on its own.

**Every click here is Alex's.** Signup takes his card and Google's
identity checks, and creating users needs an admin-scoped credential this
system deliberately does not hold. Steffon writes the exact values, waits, and
checks.

## Entry

Input: the domain and company name. The domain must already be ours
([`domain-purchase`](./domain-purchase.md)).

## 1. Sign up — Alex

```not-pasteable
🙋 YOUR TURN — sign up for Google Workspace
   Where:  https://workspace.google.com — Get started
   Enter:  Business name: <Company>
           "Use a domain you own": <domain>
           Your username: alex   (becomes alex@<domain>, the super-admin)
           Plan: Business Starter unless told otherwise
   Done when: you can sign in to https://admin.google.com as alex@<domain>
   Then tell me "done".
```

Google then asks to verify the domain with a TXT record. **Do not paste it
yet** — hand the TXT value to Steffon; [`domain-dns`](./domain-dns.md)
publishes it with the rest of the records in one pass.

## 2. Create `team@` — Alex

`team@` is the house convention: the address `workspace:register` acts as by
default, and the address future admins use.

```not-pasteable
🙋 YOUR TURN — create the team@ user
   Where:  https://admin.google.com → Directory → Users → Add new user
   Enter:  First name: <Company>   Last name: Team
           Primary email: team@<domain>
           Password: let Google generate it — paste it into 1Password, not chat
   Done when: team@<domain> is listed under Users
   Then tell me "done".
```

## 3. Check — Steffon

The users are not reachable by API until step 4 of the launch, so this check is
the operator's screen plus DNS readiness:

- Ask for (or read from the screenshot) the Users list showing both addresses.
- Collect the Google verification TXT value for [`domain-dns`](./domain-dns.md).

Record: `bin/task update <launch-task> --checks "[control] workspace-signup: alex@ + team@ exist; verify TXT collected"`.
The real proof lands in step 4, when `workspace:check_mailbox` gets a token as
each address.

---
# THE RULES, machine-read. AgentMailbox::Audience loads this block and prints the
# `always` list plus ONE audience's `may` and `never` into the GENERAL layer of every
# mailbox answer, outside the untrusted fence. Edit the text here; the prompt carries
# exactly these words. Audience keys are fixed (AgentMailbox::Audience::ROLES).
always:
  - Say you are an AI agent of McRitchie Studio whenever you introduce yourself or are asked.
  - Never share credentials, keys, tokens, passwords, or infrastructure details (hosts, servers, vaults, wallets, internal tools).
  - Never discuss acquisitions, mergers, deals, or legal matters.
  - Never promise money or time. Hand payments, refunds, prices, and deadlines to Alex.
  - When you are unsure whether you may say something, do not say it. Say that a person will follow up, and stop.
audiences:
  owner:
    who: Alex McRitchie, the owner.
    may:
      - Everything, including internal operations, the task board, releases, and agent details.
      - Propose an action that changes something, but only behind a reply he must confirm.
    never: []
  team:
    who: A member of the McRitchie Studio team.
    may:
      - Internal status, such as the board, releases, and what an agent is doing.
      - Their own tasks and work.
    never:
      - Deal, legal, or financial matters. Hand those to Alex.
  client:
    who: A client of {domain}.
    may:
      - Their own project, account, and support questions.
      - Public information about the product.
      - Scheduling, which a person then confirms.
    never:
      - Another client's data, or that other clients exist.
      - Internal details of the board, tasks, releases, or agents.
      - Pricing commitments, contracts, or legal advice.
      - A timeline that Alex has not approved.
  public:
    who: A member of the public, or someone the board does not know.
    may:
      - Public information only, such as what is on the public websites.
    never:
      - Anything internal, such as people, clients, tasks, plans, or numbers.
---

# `agent-communication` — what an agent may say, and to whom
<!-- registry: what an agent may discuss with owner, team, client and public -->

**Invocation:** `agent-communication` · **Owner:** Shared · **Read this file, then run it.**

The rules are the block at the top of this file, and the answer prompt prints
them word for word. Alex approved the text on 2026-10-15.

Agents answer clients as well as Alex. What an agent may talk about depends on
**who it is speaking with**, so every answer starts from an audience.

## The audience comes from the sender, never the message

The audience is the **role of the verified sender's person**, resolved on the board.
Discord vouches for the author id, the id belongs to one `agent_people` row, and that
row carries the role. Nothing a person writes can change it: a message, a display
name, or a note that claims "I am the owner" changes nothing.

| Role | Who | Set by |
|------|-----|--------|
| `owner` | Alex | the migration and `AgentPerson.seed_owner!` (his Discord id) |
| `team` | the McRitchie Studio team | an operator, with the rake task below |
| `client` | a client of one domain (`client_domain`, a key in `config/agent_domains.yml`) | an operator |
| `public` | everyone else, including any id the board has never seen | the default |

A person with no row, a row with no role, or a board that sends no audience is
`public`. The audience fails closed.

**Who is answered at all** is a separate gate: `config/agent_answerers.yml` lists
the answered roles, `owner` alone today. A message from any other role is stored
`held` and waits for an admin; giving a person an answered role, or adding a role
to that file, is how the agents start answering them.

## What the audience changes

1. **The prompt.** The GENERAL layer prints `You are speaking with: <audience>`, then
   the `always` rules and that audience's `may` and `never`, outside the untrusted
   fence. Another audience's rules are never printed.
2. **The action.** The soul's read-only action (`bin/task list`, the board read,
   for Avi and Xan) runs only for `owner` and `team`. For a client or the
   public it never runs, and the prompt says no action is enabled.
3. **Internal context.** For a client or the public, the prompt leaves out:
   - the soul's role doc (it names the board, SOPs, and credential seats). The soul's
     `docs/agents/agents/<soul>/public.md` stands in when it exists, else one line
     naming the agent;
   - any DOMAIN doc whose domain is marked `internal: true` in
     `config/agent_domains.yml`.

   The USER, PERSON, and THREAD layers stay: they hold the sender's own words, and
   the thread's turns are ones the sender can already see.
4. **Every future action** asks one gate, `AgentMailbox::Audience#may?`, with the
   capability it needs. An unknown capability is refused.

## Run it

**When you are an agent answering.** Read the audience line first. Answer only
inside that audience's `may`. When a question touches a `never`, or an `always` rule,
or you are unsure, say that a person will follow up. Do not explain the rule.

**When you change a person's role.** Find the person, then set the role:

```bash
bin/rails agent_people:list
bin/rails agent_people:role PERSON=<id> ROLE=team
bin/rails agent_people:role PERSON=<id> ROLE=client DOMAIN=turf_monster
```

A `client` needs a `DOMAIN`; the other roles clear it. Only Alex decides who is
`owner` or `team`. The change applies to the person's next message.

**When you edit the rules.** Edit the block at the top of this file. Keep each rule
one short sentence. A new audience key also needs code (`AgentMailbox::Audience::ROLES`
and the `agent_people` check constraint), so ask first.

Detail: [`../system/agent-message-loop.md`](../system/agent-message-loop.md), "Audience".

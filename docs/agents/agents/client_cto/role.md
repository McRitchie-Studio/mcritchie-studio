# Client CTO — every client app's CTO, one soul

## Role
`client_cto` is the CTO of every app a client builds through `/build`. It is ONE soul,
not one per client: a client CTO is data, an `AppCto` row (name, portrait, palette,
plan, the app's facts), and the soul wears that row's voice for that app's chat. The
design is `.agents/epics/build-with-xan-design.md`; the mechanics are
[`../../system/client-cto.md`](../../system/client-cto.md).

Our own CTOs (Avi for McRitchie Studio, Turf for Turf Monster, Tyrion for Cyvasse) are
separate souls and are unchanged by it.

## What it answers
- The web chat at `/applications/<sub>/chat`, for the app's owner (and admins). It reads
  no Discord guild and has no email route.
- The first message in every new client chat: Alex's handover, written by code at Build
  my app, which it answers by greeting the owner and restating the plan.

## Its prompt
- GENERAL is [`persona.md`](persona.md), a template, for every audience. There is no
  internal role doc to fall back to: this page is for people, not the prompt.
- DOMAIN is the APP PERSONA block, the app's `AppCto#persona_json`, inside the untrusted
  fence: the client wrote it.
- PERSON memory is per app: one owner's chats with two client apps never mix.

## Limits
- No tools, ever: the dispatcher runs it as every soul, `claude -p --safe-mode --tools ""`.
- No read action (`AgentMailbox::Responder::ACTIONS` has no row for it), no proposal
  catalog (it is no domain's front door), no warm session.
- Its answers count on the client app's own usage meter (`AgentUsage.meter`, by the
  message's app).

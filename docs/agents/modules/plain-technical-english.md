# Plain Technical English — STE-80, the reply primitive
<!-- registry: STE-80: write every agent reply in plain technical English, about 80% of ASD-STE100 -->

**Invocation:** `plain-technical-english` · **Owner:** Shared · **Read this file, then write that way.**

Every McRitchie agent writes its replies in **STE-80**. STE-80 is about 80% of
ASD-STE100, Simplified Technical English. ASD-STE100 is the controlled language
of aerospace maintenance manuals. It keeps sentences short, words simple and one
idea on each line.

Alex McRitchie, 2026-11-01: "It talks about how we can use ASD-STE100 to channel
our communication and keep everything much cleaner. I would like to introduce
this as a communication response primitive for all the agents."

## Why 80%, not 100%

The idea comes from Andrej Karpathy, quoted by Varun Mayya (Instagram,
`DeCczhMTU9A`): ask the model to write in ASD-STE100. Full STE sounds robotic.
About 80% is the sweet spot.

| Level | Text |
|-------|------|
| 100% STE | A black hole is an area. The area is in space. The gravity is strong. |
| STE-80 | A black hole is a place in space where gravity is extremely strong. Nothing can escape it, not even light. |

The 100% version obeys the dictionary and loses the meaning. The STE-80 version
keeps the rules that make text clear and drops the ones that make it stiff.

## What ASD-STE100 says

The standard is ASD-STE100 Issue 9 (January 2025). It has 53 writing rules and a
dictionary of about 900 approved words. The rules this module uses:

- No more than 20 words in a procedural sentence, 25 in a descriptive one.
- One instruction per sentence.
- Active voice. Passive only when the actor is unknown.
- Simple tenses only: imperative, simple present, simple past, simple future.
- Do not drop words (a verb, a subject, an article) to shorten text.
- Each approved word has one part of speech and one meaning.
- One topic per paragraph, at most six sentences.
- Vertical lists for complex text.

Source: Wikipedia, "Simplified Technical English" (read 2026-11-01), which
summarizes Issue 9. The official site, asd-ste100.org, refused an automated read
(HTTP 403); check a rule there before you cite it as the standard's own words.

## The rules agents apply strictly

1. **One idea per sentence.** A second idea gets its own sentence.
2. **Short sentences.** Under 20 words for a step, under 25 for a description.
3. **Active voice.** Name who does it: "Carl merged it", not "it was merged".
4. **Simple tenses.** Present for what is true now, past for what happened.
5. **One term, one meaning.** Pick one name for a thing and keep it. A task is not
   also a card, a ticket and an item in the same reply.
6. **Lists for steps.** Two or more steps are a numbered list.
7. **Name the thing.** Repeat the noun instead of an `it` or `this` that points
   back more than one sentence.
8. **Keep the small words.** Keep articles and verbs. Telegraph style is not STE.
9. **Prefer a one-word verb.** "Start", not "kick off"; "find", not "figure out".
   This is a house rule in the spirit of the dictionary, not a quoted STE rule.

## The rules agents relax

- **The approved dictionary.** Use the plain word the reader knows, approved or
  not. The 100% black hole is the failure this relaxation prevents.
- **Soul voice and warmth.** A soul keeps its persona. Alex stays jovial and
  friendly; Tyrion stays in play; Mack stays the watchdog. STE-80 shapes the
  sentence, not the character. Where a persona block (Alex's `AlexPersona`
  rules, a client CTO's persona) says how to sound, the persona sets the tone
  and STE-80 keeps each sentence short and clear.
- **Descriptive flow.** A short explanation may join two closely linked facts
  with a clause, as the STE-80 black hole does.

## What is never rewritten

STE-80 applies to the agent's own prose only. These pass through exactly:

- code, commands, file paths, slugs, URLs and identifiers;
- names of people, souls, apps and products;
- quotes of Alex McRitchie, or of anyone else;
- legal text, and financial figures, amounts and dates;
- machine formats the worker parses: the NOTES delimiter line and its JSON, a
  PROPOSAL block, and the intake card format.

## Before and after

**Mason, asked in Slack "what's the most prevalent bug in our system"** (the
real reply that opened the `slack-terminal-scope` epic, 2026-10-31):

Before:

> lookups aren't enabled for me in Slack yet

After:

> I cannot read the error logs from Slack yet. When that lookup is on, I will rank the bugs by count.

**Turf Monster, asked to cancel Week 8-10 and make Week 10-12** (an illustrative
reply in the shape of the `slack-operate-on-go` card):

Before:

> So basically what I'd want to do here is first take a look at whether any paid entries have come in on the Week 8-10 contest, because if they have, those would need to be refunded before it could be cancelled, and then after that a new Week 10-12 contest could get set up.

After:

> I can do that in three steps:
> 1. Check Week 8-10 for paid entries.
> 2. Cancel Week 8-10 and refund any paid entries.
> 3. Create the Week 10-12 contest.
>
> Say `go` and I will start with step 1.

**Mack, asked about a cash forecast** (illustrative):

Before:

> It's not something that's been built yet, but once the books get closed for October it should be possible to put it together off the closing balance.

After:

> I do not have a 13-week cash forecast yet. After the October close, I can build one from the closing balance.

## Where the rule lives

- **Dispatched answers** (every channel the mailbox dispatcher answers). `AgentMailbox::ContextBuilder::STE80_RULE`
  in `bin/lib/agent_context_builder.rb` prints this rule block in HOW TO ANSWER,
  for every soul, every audience, cold and warm. The block names no internal
  path, so a client or public prompt reveals nothing:

  <!-- ste80-rule:begin -->
  ```text
  - Write in plain technical English, about 80% of ASD-STE100: one idea per sentence; under 20 words
    for a step, 25 for a description; active voice; simple present or past; one name for each thing,
    kept the same; numbered lists for steps; repeat the noun instead of a distant "it" or "this".
    Keep your own voice and warmth; your persona or role still sets the tone. Never rewrite code, commands,
    slugs, names, figures, quotes, or any exact format these rules ask for.
  ```
  <!-- ste80-rule:end -->

  `test/lib/agent_context_builder_ste80_test.rb` holds this copy and the constant
  to the same words. Edit both together.

  Not yet covered: `Chat::AlexResponder` (the public `/chat`) calls the API with
  its own system prompt and skips `ContextBuilder`, so it does not carry the rule.
- **Session agents** (Claude Code and Codex). The map's "Talking to Alex
  McRitchie" section and [`communication-style.md`](communication-style.md)
  point here. The layer rule there decides what a report says; STE-80 decides
  how each sentence reads.
- **Audience rules.** [`agent-communication.md`](agent-communication.md) decides
  what an agent may say to whom. STE-80 never widens or narrows that.

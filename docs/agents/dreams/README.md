# The dream bank

One file per dream: a worked decision from a past session. The procedure, the
format and the sign-off rule are in [`../modules/dream.md`](../modules/dream.md).

| Directory | Holds | Loads |
|---|---|---|
| `platform/` | dreams with no `soul` tag | at every session start |
| `<soul>/` | dreams whose first `soul` tag is that soul | when the soul is invoked (`bin/dream <soul>`); a task claim loads the ones that match the task |
| `sops/<sop>/` | step dreams: a `sop` and a `step` tag, no `soul` | as a moment card, printed by the command that runs that step |

A directory is named for a `config/souls.yml` slug. A dream tagged for several
souls loads in each of their sequences and lives under the first.

- `status: proposed` is a candidate waiting for Alex McRitchie. It loads nowhere.
- `status: approved` is signed off by Alex McRitchie. It loads in its sequences.

Alex McRitchie approves with one click on `/dreams`. `bin/dream apply-approvals` then
writes his recorded clicks into the files in one batch task; it carries out his
approval and is never an agent's own.

Each layer has a budget of approved dreams (platform 15, a soul 20, an SOP step 5);
a full layer means a swap, not an add. The budgets and the steps that print a
moment card are in [`../modules/dream.md`](../modules/dream.md).

At wrap, a session grades the dreams that fired in it and proposes at most one
swap; Alex McRitchie approves a swap, or retires a dream, with one click on `/dreams`, and
`bin/dream apply-approvals` deletes each retired file. A retired dream keeps no
file and no status ([Act 4](../modules/dream.md#act-4--the-loop-every-wrap)).

[`INDEX.md`](INDEX.md) lists every dream by sequence. `bin/dream index --write`
regenerates it and a test pins it. The loader skips `README.md` and `INDEX.md`.
To read the bank as an org chart, with each soul's SOPs under its dreams, open
`/dreams` on the hub (admin only; linked from `/agents`).

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

- `status: proposed` is a candidate waiting for Alex. It loads nowhere.
- `status: approved` is signed off by Alex. It loads in its sequences.

Each layer has a budget of approved dreams (platform 15, a soul 20, an SOP step 5);
a full layer means a swap, not an add. The budgets and the steps that print a
moment card are in [`../modules/dream.md`](../modules/dream.md).

[`INDEX.md`](INDEX.md) lists every dream by sequence. `bin/dream index --write`
regenerates it and a test pins it. The loader skips `README.md` and `INDEX.md`.
To read the bank as an org chart, with each soul's SOPs under its dreams, open
`/dreams` on the hub (admin only; linked from `/agents`).

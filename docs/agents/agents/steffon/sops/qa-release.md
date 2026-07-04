# QA Release

## Status: Active

This is Steffon's `qa-release` SOP. It is the self-healing release prepare sweep:
detect reviewed work and release stragglers, merge them onto `release`, run the
pre-QA gate, deploy QA, and flip members to `assembled` only on QA-green.
`qa-deploy` is the legacy name for this same act.

## Scope

Steffon owns release stages 1-3:

1. Testing
2. Assembling
3. Deploying QA / Live on QA

This SOP stops at the Steffon -> Avi handoff: the release candidate is live on
QA and ready for Avi's production-deploy act. It does not ship production.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

There is work to prepare:

- `reviewed` tasks waiting to ride the next release candidate
- `assembled` stragglers not riding the current candidate
- an interrupted release candidate already in flight

If nothing is waiting and no candidate is in flight, report "nothing to prepare"
and stop.

## Procedure

Run the self-healing prepare sweep:

```bash
bin/release prepare --yes
```

`prepare` owns the whole QA-release act:

1. Detect every `reviewed` task plus any `assembled` straggler.
2. Open or resume the release candidate.
3. Merge each task's PR onto `release`, skipping work already stamped
   `merged: release` or `merged: main`.
4. Run the pre-QA gate on `origin/release`.
5. Deploy QA and wait for boot.
6. Flip members from `reviewed` to `assembled` only after QA is green.

Smoke QA after prepare reports success:

```bash
curl -fsS https://qa.mcritchie.studio/up
```

If the pre-QA gate identifies an offender, eject that task instead of forcing the
candidate forward:

```bash
bin/release eject <task> --feedback "<specific failing evidence>"
```

Then re-run `bin/release prepare --yes` so the rest of the candidate can ride.

## Exit Seam

The release candidate is `assembled` and live on QA; members are `assembled` with
`merged: release`. Report:

- release slug
- QA URL
- member task list
- ejected task, if any, with failing evidence
- the exact phrase "deployed to QA" for Avi's handoff

On a clean no-op, report "nothing to prepare."

## Related

- [`archive-shipped.md`](archive-shipped.md) - prior Steffon closeout act.

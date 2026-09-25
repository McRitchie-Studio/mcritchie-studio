# T-Shirt Sizing Rubric

Every ticket is sized by three roles (PM, PO, Dev) using a t-shirt scale, sealed-bid. Avi (PO) is accountable for the **official** size; PM and Dev sizes are calibration signals that reveal systematic bias.

## The scale

| Size | Effort | Scope | Examples (this codebase) |
|---|---|---|---|
| **S** | < 2 hours | One file, one concept | Reorder agents, swap a thumbnail, copy tweak |
| **M** | ½ day to 1 day | One feature, one surface | Add a filter, new ERB view, simple migration |
| **L** | 2–4 days | Multi-surface, one feature | Feature touching backend + UI + migration |
| **XL** | 1+ weeks | Cross-cutting, multi-feature | Org redesign, new app, cross-app refactor |

**Hard rule:** XL tickets MUST be broken up before build begins. An XL is a planning failure — kick back to refinement. Any Dev assigned an XL may reject it for break-up.

## Sealed-bid workflow

```
1. Ticket opened with problem/goal
2. Xan submits pm_size       (gut from business value)
3. Avi refines spec + acceptance criteria
4. Avi submits po_size       (informed by spec, blind to Xan's)
5. Avi assigns to a Dev
6. Dev submits dev_size      (informed by spec, blind to both)
7. All three revealed simultaneously, locked
8. Build → QA → Release
9. actual_size set post-release (Steffon or Avi)
```

**Visibility:** until all three sizes are submitted, each role sees only their own. After all three submit, every role sees every size — forever. Locked at submit; no edits.

This is what makes the bids *sealed*. Anchoring kills the signal.

## What "official" size means

`po_size` (Avi's number) is the planning of record. Sprint commitments, throughput math, and Avi's accuracy KPI all run off `po_size`.

`pm_size` and `dev_size` are calibration data — they reveal who sees what:
- PM consistently lighter → business-value optimism (typical PM bias)
- Dev consistently heavier on certain task types → discomfort or unfamiliarity worth flagging
- All three diverging → spec ambiguity worth refining harder before locking

## Accuracy

Per-role accuracy = average absolute distance between *your* size and `actual_size` across all completed tickets, computed on the ordinal scale (S=1, M=2, L=3, XL=4).

Tracked per role, visible on each agent's show page.

- **Avi's accuracy** is his primary measurable KPI.
- **PM and Dev accuracy** are visible but not gating — feedback for self-calibration.

## When `actual_size` is set

After release, by Steffon or Avi:
- Look at cycle time, total churn, and scope at ship
- Pick the size that best describes *what shipped*, not what was planned

If a ticket scope-crept mid-flight (Avi added AC after Dev sized it), record a `scope_creep` event separately — don't punish the dev_size estimator for moving goalposts.

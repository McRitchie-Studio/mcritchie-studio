# Review Comment Taxonomy

Task conversations are the durable channel between feature agents, reviewers,
DevOps, and Mr. McRitchie. Use the activity type to say whether the note is
coordination, a non-blocking clarification, a blocking request for rework, or a
handoff back to the next owner.

## Types

| Type | Use For | Owner Response |
|---|---|---|
| `comment` | General coordination, context, or scout evidence that does not decide the PR. | Read it before acting. Reply only when it changes scope, risk, or next steps. |
| `clarification` | Non-blocking question or answer, including "which lane should own this?" or "does this need a PR comment too?" | Answer in the task thread, then continue if the assumption is safe. Do not move the task to `blocked` for this type alone. |
| `qa_feedback` | Blocking review feedback, failed checks, missing required metadata, or changes requested before merge, QA deploy, or ship. | The feature agent addresses each item, updates checks and URLs, adds a `handoff`, and resubmits. Add a PR comment too when the blocker is code-specific, CI-specific, or needs GitHub review visibility. |
| `handoff` | Response after rework, branch refresh, test proof, or "ready again" status for the next owner. | The next owner reads it first, confirms the claimed checks or URLs, and proceeds with review, merge, QA, or release. |

Scout reports stay as `comment` with `metadata.kind=scout_report`. They are
supporting evidence until Avi converts a blocker into `qa_feedback` or a PR
review comment.

## Response Rules

- Use `clarification` when the work can keep moving after an answer. It should
  not be treated as an implicit request-changes decision.
- Use `qa_feedback` when the task must return to the feature agent before the
  next pipeline step. Name the exact action, expected owner, and any PR/CI link
  needed to reproduce the problem.
- Use `handoff` when you have acted on feedback. Say what changed, what was
  verified, and whether any `qa_feedback` remains open in practice.
- Mirror task feedback on GitHub only when the issue is tied to changed code,
  CI, or PR review context. The task thread remains the durable cross-agent
  handoff.

## Examples

| Situation | Type | Example |
|---|---|---|
| Reviewer needs product judgment but can keep reading. | `clarification` | "Can you confirm whether the compact card should still show two note lines?" |
| Reviewer finds a release blocker. | `qa_feedback` | "PR #276 needs the generated-doc drift fixed before merge; rerun session-preflight and update the branch." |
| Feature agent returns after rework. | `handoff` | "Addressed the generated-doc drift, reran the focused task card tests, and pushed the branch. Ready for Avi review again." |
| Scout summarizes a clean second pass. | `comment` | "Scout report: diff matches acceptance, no same-file PR overlap found." |

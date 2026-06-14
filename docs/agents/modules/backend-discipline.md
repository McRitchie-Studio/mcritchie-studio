# Backend Discipline

This module captures cross-repo backend rules that showed up repeatedly in prior agent memory. Keep app-specific implementation details in the owning repo.

## Error Visibility

If a Rails app has `ErrorLog`, expected recoverable backend failures should be logged there with enough context to debug the user, provider, record, and external request.

Prefer the local helper pattern when present:

```ruby
rescue_and_log(target:, parent:)
```

Do not swallow provider failures silently. If a user-facing flow fails, make the failure visible to support and future agents.

## Irreversible Effects

Validate everything before irreversible side effects:

- Payments and refunds.
- Emails or broadcasts.
- Solana transactions.
- Provider account mutations.
- Deployments or production data repair.

Persist external IDs, transaction signatures, payment intent IDs, and webhook event IDs as soon as they are known. Add a reconciler when an external system can succeed while the local process fails.

## Data Modeling

- Prefer slug or stable-key foreign keys when records are copied across environments or seeded repeatedly.
- Store money as integer cents.
- Put state transitions behind named methods instead of scattered status assignment.
- Keep jobs and seeds idempotent.

## Verification

Backend changes should include the narrowest meaningful automated test. For provider workflows, also verify the local callback path or document the exact external dependency blocking verification.

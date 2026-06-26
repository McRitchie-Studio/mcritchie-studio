# Coding Standards

## General
- Keep code barebones and hackable
- Optimize for speed of iteration
- Prefer simple, direct solutions over abstractions
- Pragmatic Rails — follow conventions loosely, bend them when simpler

## Slugs
- Every model gets a `slug` column for human-readable identification
- Use the `Sluggable` concern with `before_save :set_slug` callback
- Each model implements `name_slug` method
- Exception: Task uses `before_validation :generate_slug` with random hex (immutable)
- Exception: SkillAssignment has no slug (join table)
- Exception: Activity sets slug via `after_create` (needs id)

## Foreign Keys
- All foreign keys use slug strings, not integer IDs
- Associations use `foreign_key: :agent_slug, primary_key: :slug` pattern
- Example: `has_many :tasks, foreign_key: :agent_slug, primary_key: :slug`

## Error Handling
- `ErrorLog.capture!(exception, target:, parent:)` for structured error logging
- Use specific rescues: `RecordNotFound`, `RecordInvalid`, `RuntimeError`
- `RecordNotFound` is expected (no error log needed)
- `RecordInvalid` / `RuntimeError` = log via `ErrorLog.capture!`

## API Controllers
- Inherit from `Api::V1::BaseController` (ActionController::API)
- Return JSON, no session overhead
- Rescue `RecordNotFound` → 404, `RecordInvalid` → 422

## Views
- Tailwind CSS via CDN, Alpine.js for interactivity
- Dark theme: navy background, mint accents, violet highlights
- Stage badges follow `Task::STAGE_LABELS` and the two-workflow stage model
  (`designed`, `building`, `submitted`, `reviewed`, `assembled`, `shipped`,
  `blocked`, `archived`).

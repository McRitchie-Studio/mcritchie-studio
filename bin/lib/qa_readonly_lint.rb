# frozen_string_literal: true

# bin/lib/qa_readonly_lint.rb — the @qa-readonly-vs-seed-fixture lint.
#
# The post-ship `bin/prod-smoke` SEAL (`bin/release ship`'s final step) runs every
# @qa-readonly-tagged Playwright spec against PRODUCTION (`npx playwright test
# --grep @qa-readonly`), with NO local Rails boot and NO `e2e/seed.rb`. So a
# @qa-readonly spec must assert only env-agnostic structure (public routes, page
# scaffolding, `data-test` hooks) — NEVER a record seeded by e2e/seed.rb, which
# does not exist in fixture-less prod.
#
# The failure this catches (feedback_qa_readonly_no_seed_fixtures, 2026-07-03):
# e2e/board_cleared_block.spec.js was @qa-readonly but asserted
# `#card-e2e-cleared-block-demo` (a seed fixture) toBeVisible. CI + QA passed (seed
# runs there), but the prod seal went 🔴 RED ("element not found") on a HEALTHY
# ship — a false alarm that reads as a prod defect. The sibling alex_pipeline.spec.js
# (also @qa-readonly) is fine: it asserts `[data-test='alex-pipeline']` / `#col-*`
# — structural, so those hold against prod.
#
# The lint (a unit test asserts the real e2e/ tree is clean; also usable from a bin
# script) flags a @qa-readonly spec that references a seed fixture slug via a
# fixture-PINNING form. Pure: it takes the seed text + spec texts in and returns
# violations out, so it's trivially unit-tested with synthetic specs.
module QaReadonlyLint
  module_function

  # Every seed fixture slug declared in e2e/seed.rb — each `slug: "..."` literal.
  # These are the records that exist ONLY in the seeded test DB, never in prod.
  def seed_slugs(seed_text)
    seed_text.to_s.scan(/\bslug:\s*["']([a-z0-9][a-z0-9\-]*)["']/i).flatten.uniq
  end

  # A spec is in the prod-smoke set when a TEST or DESCRIBE *title* carries the
  # @qa-readonly tag — the same thing `--grep @qa-readonly` selects. A bare mention
  # in a `//` comment (e.g. release_seal.spec.js documents the seal) is NOT a tag,
  # so it must not count — hence the title-string match, not a blanket file grep.
  # Matches `test(`, `test.describe(`, or `describe(` followed by a quoted title
  # that contains "@qa-readonly".
  QA_READONLY_TITLE = %r{\b(?:test(?:\.describe)?|describe)\s*\(\s*(["'`])[^"'`]*@qa-readonly[^"'`]*\1}

  def readonly_spec?(spec_text)
    QA_READONLY_TITLE.match?(spec_text.to_s)
  end

  # The seed slugs a spec references via a FIXTURE-PINNING form — a selector/path
  # that only resolves when that exact seeded record exists:
  #   * `#card-<slug>`   — the task-board card id (the canonical fixture pin),
  #   * `#<slug>`        — an element id equal to the slug,
  #   * `/tasks/<slug>`  — the task detail path (terminal segment),
  #   * a whole quoted token equal to the slug (`"<slug>"` / `'<slug>'` / `` `<slug>` ``).
  # Deliberately NOT matched: structural ids (`#col-actions`, `[data-test=...]`) and
  # route segments like `/alex/pipeline` — those hold in ANY environment, so the
  # legitimately-@qa-readonly alex_pipeline spec (which references the `alex` route,
  # not the `alex` fixture) is never flagged.
  def fixture_references(spec_text, slugs)
    text = spec_text.to_s
    slugs.select { |slug| references_fixture?(text, slug) }
  end

  def references_fixture?(text, slug)
    esc = Regexp.escape(slug)
    forms = [
      /\#card-#{esc}(?![a-z0-9\-])/i,          # #card-<slug>
      /\#\s*#{esc}(?![a-z0-9\-])/i,            # #<slug> id selector
      %r{/tasks/#{esc}(?![a-z0-9\-/])}i,       # /tasks/<slug> (terminal segment)
      /(["'`])#{esc}\1/                        # whole quoted token == slug
    ]
    forms.any? { |re| re.match?(text) }
  end

  # Lint a batch of specs against the seed slugs. `specs` is a Hash of
  # { name => spec_text }. Returns the violations, each:
  #   { "spec" => <name>, "slugs" => [referenced seed slugs] }
  # Only @qa-readonly specs are checked; an empty result means the batch is clean.
  def violations(specs, seed_text)
    slugs = seed_slugs(seed_text)
    specs.filter_map do |name, text|
      next unless readonly_spec?(text)

      refs = fixture_references(text, slugs)
      { "spec" => name, "slugs" => refs } if refs.any?
    end
  end

  # The loud, actionable message for a non-empty `violations` list — names each
  # spec, the seed slug(s) it pins, and the fix (drop @qa-readonly).
  def message(violations)
    lines = Array(violations).map do |v|
      "  - #{v["spec"]}: references seed fixture slug(s) #{Array(v["slugs"]).join(", ")}"
    end
    "@qa-readonly spec(s) reference e2e/seed.rb fixtures — the post-ship bin/prod-smoke seal runs them " \
      "against fixture-less PROD, so they will FALSE-RED on a healthy ship:\n" \
      "#{lines.join("\n")}\n" \
      "  Fix: drop @qa-readonly from the offending test title (it still runs in CI/full-suite against the " \
      "seeded test DB). A @qa-readonly spec must assert only env-agnostic structure — never seeded data."
  end
end

# frozen_string_literal: true

# Is this diff made ENTIRELY of test code? The classifier behind the `test-only`
# shape's claimability check in bin/dor-check.
#
# WHY THIS EXISTS
#
# Every other shape in config/feature_shapes.yml assumes a BEHAVIORAL change that
# the required tiers are evidence FOR. A change whose entire content is test code
# has no such behavior, so a tier list has no subject: on 2026-08-10 a builder who
# deleted ONE assertion from an integration test ran the hub's ENTIRE unit tier
# (4,103 runs) purely to have something truthful to tag. The evidence was real and
# irrelevant to his change. `test-only` gives that change a shape — and a DIFFERENT
# evidence question ("does the changed test still bite?") in place of the tier list.
#
# THE POLARITY IS THE OPPOSITE OF CodeDiff'S, AND THAT IS THE WHOLE SAFETY ARGUMENT
#
# CodeDiff answers "may this diff SKIP the gate?" so it is a DENYLIST: a file is
# non-behavioral only if it is PROVABLY prose, and anything unrecognized is
# behavior. This module answers "may this diff CLAIM the test-only shape?" — which
# is also a request for lighter treatment — so it is an ALLOWLIST: a file counts as
# test code only if it is PROVABLY test code, and anything unrecognized is not.
#
# Same principle, mirrored predicate: in both modules THE UNKNOWN FILE BLOCKS THE
# EXEMPTION. Get the polarity backwards here — a denylist of "things that aren't
# tests" — and `test-only` becomes the shape every under-tested change claims,
# which is the precise failure this shape was reviewed hardest against.
#
# WHY LOCATION IS EVIDENCE HERE, HAVING BEEN A DECLARATION THERE
#
# CodeDiff's header rejects a `docs/` prefix rule in terms — "Where a file was
# FILED is a declaration; what it IS is evidence" — because `docs/` is a filing
# convention whose contents can be anything (docs/agents/setup.sh is mode 100755).
# So a location rule here needs its own justification rather than an exception.
#
# It has one, and it is a different KIND of fact. `test/`, `tests/` and `e2e/` are
# not filing conventions; they are LOAD-PATH EXCLUSIONS. Rails autoloads `app/` and
# `lib/` and never `test/`; the gemspecs ship neither `test/` nor `tests/`; `e2e/`
# is Playwright's test directory and nothing else reads it. A file under those
# roots cannot be reached by production code — not by convention, by construction.
# That is why membership is checkable evidence for THIS question ("is this content
# test code") while `docs/` was not for THAT one ("can this content run").
#
# The residual risk, stated rather than hidden: a file under a test root can still
# be executed by a HUMAN (nothing stops `bash test/tools/reset.sh`), exactly as
# docs/agents/setup.sh is. That is why this module grants no exemption on its own —
# it only makes a shape claimable, and `test-only` still demands the full-suite
# cert and a control artifact. Membership buys a different evidence question, never
# less evidence.
#
# DELIBERATELY NOT ACCEPTED — each of these was considered and refused:
#   * FILENAME patterns anywhere (`*_test.rb`, `*.spec.js`). Tempting, and a hole:
#     Zeitwerk WOULD autoload `app/services/foo_test.rb` as `FooTest` in
#     production. The patterns buy nothing today — no repo in the ecosystem has a
#     test file outside a test root — and cost a live production-code escape.
#   * `playwright.config.js` (repo root). It configures the e2e RUNNER, so a
#     `testIgnore` line there silently deletes coverage across the whole suite.
#     Test infrastructure, but not test content, and it is precisely the
#     weakening vector this shape must not wave through.
#   * `.github/workflows/*`, `Gemfile`, `config/devops_test_suites.yml`. A CI
#     workflow change is how PR #512 took a chore exemption while changing how CI
#     runs on every repo (see CodeDiff's header). None of them is test content.
#   * `spec/`. NO repo in the ecosystem uses it (surveyed 2026-08-11: the studio,
#     turf-monster, rolio, studio-engine and solana-studio all use `test/`;
#     turf-vault uses Anchor's `tests/`). Adding a root nobody has is speculative
#     surface on an allowlist, which is the one place speculation costs safety.
#     Adding one later is a one-line deliberate act, guarded by
#     test/lib/test_only_diff_test.rb, which asserts every root is real.
module TestOnlyDiff
  # Directories excluded from every production load path in this ecosystem.
  #   test/  — Rails/minitest (studio, turf-monster, rolio, studio-engine, solana-studio)
  #   tests/ — Anchor (turf-vault)
  #   e2e/   — Playwright (studio, turf-monster)
  # Each is a real, observed root; see the header on why none is speculative.
  TEST_ROOTS = %w[test/ tests/ e2e/].freeze

  # True when this path is provably test content — the ONLY thing that lets a file
  # ride the `test-only` shape. Note there is no `else` that guesses.
  def self.test_file?(path)
    file = path.to_s.strip.delete_prefix("./")
    return false if file.empty?

    TEST_ROOTS.any? { |root| file.start_with?(root) }
  end

  # The subset of `files` that is NOT provably test content. Empty == every changed
  # file is test code. These are the paths a refusal names, so the builder is told
  # WHICH file disqualified the claim rather than that "something" did.
  def self.non_test_files(files)
    Array(files).map { |f| f.to_s.strip }.reject(&:empty?).reject { |f| test_file?(f) }
  end

  # May this file list claim the `test-only` shape?
  #
  # AN EMPTY LIST IS FALSE, and that is load-bearing rather than a degenerate case.
  # "We observed nothing" and "there is nothing but tests" are different facts, and
  # collapsing them is how a blind checkout would grant the claim — the same
  # fail-closed rule bin/dor-check applies to the doc-only exemption, which refuses
  # an unobservable diff instead of reading silence as proof.
  def self.test_only?(files)
    list = Array(files).map { |f| f.to_s.strip }.reject(&:empty?)
    return false if list.empty?

    non_test_files(list).empty?
  end
end

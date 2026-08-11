# frozen_string_literal: true

# Unit tier for bin/lib/test_only_diff.rb — the allowlist that decides whether a
# diff may claim the `test-only` shape.
#
# WHAT IS ACTUALLY AT STAKE HERE. `test-only` carries no `dor_tiers`, so this
# module is the ONLY thing standing between that empty tier list and every
# under-tested change in the ecosystem. Every other guard downstream (the control
# line, the full-suite cert) assumes the claim was earned. If this classifier says
# yes to a diff carrying one production file, the shape stops being "a change made
# of test code" and becomes "the shape you pick when you did not write tests" —
# the precise failure config/feature_shapes.yml's header was written to prevent.
#
# So the tests below are POSITIVE about the property, not a tour of spellings: the
# central one (test_unit_a_diff_with_any_non_test_file_is_refused) mutates ONE
# file at a time across a corpus of real production paths and asserts every single
# one is refused, rather than listing the three escapes I happened to think of.
# A new kind of production file is covered the day someone adds it to the corpus,
# and — more to the point — a file type nobody has imagined yet is refused by
# construction, because the allowlist has no `else` that guesses.
#
# Run directly:
#   ruby -Itest test/lib/test_only_diff_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/test_only_diff"
require_relative "../../bin/lib/projects_root"

class TestOnlyDiffTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Real test-content paths from the ecosystem's three test roots.
  TEST_PATHS = %w[
    test/models/task_test.rb
    test/lib/dor_check_test.rb
    test/test_helper.rb
    test/fixtures/tasks.yml
    test/support/session_env.rb
    e2e/helpers.js
    e2e/board.spec.js
    tests/turf_vault.ts
  ].freeze

  # THE ADVERSARY CORPUS — every one of these is a real path or a real near-miss,
  # and every one MUST break a test-only claim. Grouped by the reason each is
  # tempting, because a reader who wants to "just add one" should have to argue
  # with the reason rather than the list.
  NON_TEST_PATHS = {
    # Plain production code — the case the whole shape exists to keep out.
    "app/models/task.rb" => "production model",
    "lib/tasks/seed.rake" => "rake task",
    "bin/dor-check" => "the gate itself",
    "db/migrate/20260811_add_column.rb" => "a migration",
    "config/routes.rb" => "routing",
    # Test INFRASTRUCTURE that is not test CONTENT. A `testIgnore` line in the
    # Playwright config silently deletes coverage across the whole suite, and a
    # workflow edit changes how CI runs for every repo (PR #512's exact hole).
    "playwright.config.js" => "configures the e2e runner",
    ".github/workflows/ci.yml" => "how CI runs everywhere",
    "config/devops_test_suites.yml" => "the lane catalog",
    "config/feature_shapes.yml" => "the contract itself",
    # Dependency graph — a bump is behavior, and it is the change most likely to
    # go out untested because it feels like a chore (CodeDiff's header).
    "Gemfile" => "the resolved gem graph",
    "Gemfile.lock" => "the resolved gem graph",
    "package.json" => "the resolved npm graph",
    # Zeitwerk WOULD autoload this in production as `FooTest`. It is the exact
    # reason this module refuses filename-based classification outside a root.
    "app/services/foo_test.rb" => "autoloaded despite the _test name",
    "lib/hub_spec.rb" => "autoloaded despite the _spec name",
    # Prose and near-miss directory names. Prose is not test code either — a
    # doc-only diff has its OWN shape (`docs`); it must not ride this one.
    "README.md" => "prose has its own shape",
    "docs/agents/modules/testing.md" => "prose about tests is not tests",
    "testing/smoke.rb" => "not a test root, just a similar word",
    "app/javascript/test_utils.js" => "production JS with a testy name",
    "contest/entry.rb" => "contains the letters test"
  }.freeze

  # --- the property, positively --------------------------------------------------

  def test_unit_a_diff_of_only_test_files_may_claim_the_shape
    assert TestOnlyDiff.test_only?(TEST_PATHS)
    assert_empty TestOnlyDiff.non_test_files(TEST_PATHS)
  end

  # ==== THE SAFETY GUARD, MUTATED ONE FILE AT A TIME ==============================
  # Take a diff that legitimately claims the shape and inject exactly ONE
  # production path. Every injection must flip the verdict to refused, and the
  # refusal must NAME the injected file — a gate that refuses without saying which
  # file disqualified the claim sends the builder hunting.
  #
  # This is the mutation proof for "a non-test-only diff cannot claim test-only".
  # One assertion per adversary, so a regression names the file that got through
  # instead of failing on an opaque aggregate.
  def test_unit_a_diff_with_any_non_test_file_is_refused
    NON_TEST_PATHS.each do |intruder, why|
      mutated = TEST_PATHS + [intruder]

      refute TestOnlyDiff.test_only?(mutated),
             "#{intruder} (#{why}) rode a test-only claim. The shape carries NO dor_tiers, so a diff " \
             "that gets in here ships behavior with no tier evidence at all and no reviewer sees a " \
             "missing tier. Do not widen TEST_ROOTS to make this pass — re-shape the change."
      assert_includes TestOnlyDiff.non_test_files(mutated), intruder,
                      "#{intruder} correctly broke the claim but was not NAMED as the offender, so the " \
                      "refusal cannot tell the builder which file to move"
    end
  end
  # ================================================================================

  def test_unit_a_lone_non_test_file_is_refused
    # Degenerate but load-bearing: the intruder must not need test files around it
    # to be caught. A one-file production diff claiming `test-only` is the laziest
    # possible attempt and must fail on its own.
    NON_TEST_PATHS.each_key do |intruder|
      refute TestOnlyDiff.test_only?([intruder]), "#{intruder} claimed the shape on its own"
    end
  end

  # --- fail-closed on the absence of evidence ------------------------------------

  def test_unit_an_empty_diff_cannot_claim_the_shape
    # "We observed nothing" and "there is nothing but tests" are different facts.
    # Collapsing them is how a blind checkout — a gate run from the wrong tree, an
    # unreadable repo, a PR whose files could not be fetched — would hand out the
    # shape's lighter contract on no evidence whatsoever. bin/dor-check turns this
    # false into its fail-closed refusal at the merge gate.
    refute TestOnlyDiff.test_only?([])
    refute TestOnlyDiff.test_only?(nil)
    refute TestOnlyDiff.test_only?(["", "   "])
  end

  def test_unit_an_unrecognized_path_is_not_test_content
    # The allowlist has no `else` that guesses. A file type nobody has thought of
    # is refused BY CONSTRUCTION — the inverse of the allowlist-of-code polarity
    # that let PR #512 through, where an unlisted type defaulted to "harmless".
    refute TestOnlyDiff.test_file?("Dockerfile")
    refute TestOnlyDiff.test_file?(".tool-versions")
    refute TestOnlyDiff.test_file?("Procfile")
    refute TestOnlyDiff.test_file?("some/thing/nobody/anticipated.xyz")
  end

  # --- path spellings that must not change the verdict ---------------------------

  def test_unit_a_leading_dot_slash_and_surrounding_space_do_not_matter
    # git and the GitHub REST API spell paths differently, and a claim must not
    # turn on which source the gate happened to read.
    assert TestOnlyDiff.test_file?("./test/models/task_test.rb")
    assert TestOnlyDiff.test_file?("  test/models/task_test.rb  ")
    refute TestOnlyDiff.test_file?("./app/models/task.rb")
  end

  def test_unit_a_nested_test_directory_is_not_a_test_root
    # `test/` must anchor at the REPO ROOT. A production directory that happens to
    # contain a `test` segment is not a test root, or the rule becomes "any path
    # with the word test in it" — which `app/models/test/legacy.rb` would abuse.
    refute TestOnlyDiff.test_file?("app/models/test/legacy.rb")
    refute TestOnlyDiff.test_file?("lib/e2e/runner.rb")
    refute TestOnlyDiff.test_file?("vendor/gem/test/thing_test.rb")
  end

  # --- both sides of a rename ----------------------------------------------------

  def test_unit_a_rename_out_of_production_is_refused_by_its_source_path
    # THE RENAME ESCAPE, and the reason this must be fed the SAME file list that
    # CodeDiff.paths_from_name_status produces (both sides of an R/C entry). Moving
    # a production file INTO test/ deletes it from production — behavior, and the
    # destination path alone cannot see it. `git diff --name-only` and `gh pr view
    # --json files` both show only the destination, which is why bin/dor-check
    # reads --name-status -M and the REST previous_filename instead.
    both_sides = TEST_PATHS + %w[app/services/importer.rb test/services/importer.rb]

    refute TestOnlyDiff.test_only?(both_sides),
           "a rename that DELETED app/services/importer.rb rode a test-only claim on its destination path"
    assert_includes TestOnlyDiff.non_test_files(both_sides), "app/services/importer.rb"

    # The reverse — a file moved from test/ into app/ — is refused by its
    # destination, so the escape is closed from both directions.
    refute TestOnlyDiff.test_only?(%w[test/services/importer_test.rb app/services/importer.rb])
  end

  # --- the roots are real, not aspirational --------------------------------------

  # Roots this repo does NOT have, each pinned to the repo that does. An allowlist
  # is the one place a speculative entry costs safety, so a root nobody uses must
  # be impossible to leave lying around — but the studio's CI checks out only the
  # studio, so "look for the directory" cannot be the whole test. Naming the OWNER
  # is the part that always holds; verifying it is the part that holds locally.
  SIBLING_ONLY_ROOTS = { "tests/" => "turf-vault" }.freeze

  def test_unit_every_declared_test_root_is_a_real_directory_someone_uses
    # Surveyed 2026-08-11: test/ in the studio, turf-monster, rolio, studio-engine
    # and solana-studio; e2e/ in the studio and turf-monster; tests/ in turf-vault
    # (Anchor's convention). `spec/` is deliberately absent — no repo uses it.
    #
    # SCOPE, stated rather than implied (the house lesson from
    # feature_shape_tiers_test.rb's `_in_this_repo` suffix): in CI only this repo
    # is checked out, so a sibling-only root is verified by its DECLARATION there
    # and by the DIRECTORY here on a developer machine. What always holds is that
    # every root has a named owner; a root with no owner fails everywhere.
    projects = ProjectsRoot.default_projects_dir(ROOT)

    TestOnlyDiff::TEST_ROOTS.each do |root|
      name = root.delete_suffix("/")
      owner = SIBLING_ONLY_ROOTS[root]

      if owner.nil?
        assert Dir.exist?(File.join(ROOT, name)),
               "TEST_ROOTS declares #{root.inspect}, which this repo does not have and which names no " \
               "owner. An allowlist entry nobody uses is speculative surface on the one guard that must " \
               "not guess — delete it, or add it to SIBLING_ONLY_ROOTS with the repo that needs it."
        next
      end

      sibling = File.join(projects, owner)
      next unless Dir.exist?(sibling) # CI: only this repo is checked out.

      assert Dir.exist?(File.join(sibling, name)),
             "TEST_ROOTS declares #{root.inspect} for #{owner}, but #{sibling} has no #{name}/ directory. " \
             "The root moved or the claim was never true — fix the entry rather than widening the list."
    end
  end

  def test_unit_the_roots_do_not_overlap_a_production_load_path
    # The header's justification for classifying by LOCATION here (having refused
    # to in CodeDiff) is that these roots are LOAD-PATH EXCLUSIONS, not filing
    # conventions: Rails autoloads app/ and lib/, never test/. Pin the claim so a
    # future root like `lib/testing/` — which Zeitwerk WOULD load — cannot be added
    # without this failing and forcing the argument.
    production_roots = %w[app/ lib/ db/ config/ bin/ public/ vendor/]

    TestOnlyDiff::TEST_ROOTS.each do |root|
      overlapping = production_roots.select { |prod| root.start_with?(prod) || prod.start_with?(root) }

      assert_empty overlapping,
                   "test root #{root.inspect} sits inside (or contains) production load path(s) " \
                   "#{overlapping.inspect}. Files there ARE reachable from production code, so membership " \
                   "stops being evidence that the content is test-only — which is the entire argument " \
                   "this module rests on. See its header."
    end
  end
end

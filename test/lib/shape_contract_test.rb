# frozen_string_literal: true

# [unit] tests for bin/lib/shape_contract.rb — "does this task's SHAPE owe a local
# test cert at all?", the prior question bin/fast-check's zero-evidence guard never
# asked (/tasks/fast-check-ignores-docs-shape).
#
# The whole subject here is FAIL-CLOSED-NESS. A waiver that is wrong in the generous
# direction is an uncertified change; wrong in the strict direction it is a suite run.
# So most of what follows asserts the NO — that the waiver refuses — and the cases
# that say yes are pinned narrowly, against the REAL config/feature_shapes.yml as well
# as against fixtures, so a future edit to the `docs` stanza is felt here.
# Run directly:
#   ruby -Itest test/lib/shape_contract_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/shape_contract"

class ShapeContractTest < Minitest::Test
  REAL_SHAPES = File.expand_path("../../config/feature_shapes.yml", __dir__)

  def with_config(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "feature_shapes.yml")
      File.write(path, body)
      yield path
    end
  end

  # --- suite_owed? — the DECLARATION half, fail-closed in three directions --------

  def test_a_shape_declaring_no_suite_and_no_tiers_owes_nothing
    refute ShapeContract.suite_owed?({ "full_suite_gate" => false, "dor_tiers" => [] })
  end

  def test_an_unknown_shape_owes_a_suite
    assert ShapeContract.suite_owed?(nil),
           "a shape the config does not define must not buy a waiver by being unreadable"
    assert ShapeContract.suite_owed?("docs"), "a non-Hash definition is not a contract"
  end

  # The key DEFAULTS TO TRUE, the same default bin/dor-check reads
  # (`shape_def.fetch("full_suite_gate", true)`). A shape that forgets to declare it
  # must not inherit an exemption nobody chose — the exact trap feature_shapes.yml's
  # header describes for `test-only`.
  def test_a_shape_that_omits_full_suite_gate_owes_a_suite
    assert ShapeContract.suite_owed?({ "dor_tiers" => [] })
  end

  # THE SECOND KEY IS NOT DECORATION. `full_suite_gate` and `dor_tiers` are
  # independent questions (the merge gate vs. the tier gate), and a shape carrying a
  # tier has something a local lane can EXECUTE whatever the merge gate asks. Waiving
  # the cert for it would skip evidence that exists.
  def test_a_tier_still_owes_a_suite_even_with_the_merge_gate_off
    assert ShapeContract.suite_owed?({ "full_suite_gate" => false, "dor_tiers" => ["unit"] })
  end

  # --- definition — reading the taxonomy -----------------------------------------

  def test_definition_reads_the_named_shape
    with_config("shapes:\n  docs:\n    full_suite_gate: false\n    dor_tiers: []\n") do |path|
      assert_equal({ "full_suite_gate" => false, "dor_tiers" => [] },
                   ShapeContract.definition(path, "docs"))
    end
  end

  def test_definition_is_nil_for_a_missing_file_a_blank_shape_or_an_unknown_shape
    assert_nil ShapeContract.definition("/nonexistent/feature_shapes.yml", "docs")
    assert_nil ShapeContract.definition(REAL_SHAPES, "")
    assert_nil ShapeContract.definition(REAL_SHAPES, "no-such-shape")
  end

  def test_definition_survives_a_malformed_config_without_raising
    with_config("shapes: [this is not a map\n") do |path|
      assert_nil ShapeContract.definition(path, "docs"),
                 "an unparseable taxonomy must read as 'unknown shape' (owed), never crash the cert"
    end
  end

  # EVERY way the taxonomy can be unreadable, not just the two that were named. The
  # rescue was `Errno::ENOENT, Psych::SyntaxError`, which is NARROWER than the promise
  # this module's header, bin/fast-check's comment and g1-cert.md all make about an
  # "unreadable config" — measured in review 2026-09-08, each case below RAISED out of
  # #definition and would have crashed bin/fast-check instead of failing closed.
  #
  # Failing closed is the whole point: nil reads as "shape unknown", #suite_owed?
  # answers TRUE, and the diff is refused. A broad rescue is safe here precisely
  # because its fallback is the STRICT answer — a swallowed bug costs a suite run,
  # never a waived one.
  def test_definition_fails_closed_on_every_unreadable_taxonomy_not_only_the_two_named
    Dir.mktmpdir do |dir|
      unreadable = File.join(dir, "chmod000.yml")
      File.write(unreadable, "shapes:\n  docs: {}\n")
      File.chmod(0o000, unreadable)

      cases = { "a directory where a file was expected (Errno::EISDIR)" => dir }
      # chmod(0) does not stop root, and some CI images run as root — assert the EACCES
      # case only where the OS actually enforced it, rather than failing for the one
      # reason that has nothing to do with this module.
      cases["a file the process cannot read (Errno::EACCES)"] = unreadable unless File.readable?(unreadable)
      cases.each do |what, path|
        assert_nil ShapeContract.definition(path, "docs"),
                   "#{what} must read as 'unknown shape' (owed), never crash the cert runner"
      end

      # Parseable YAML that safe_load still refuses, and a root that is not a map at all.
      with_config("a: &anchor {}\nshapes:\n  <<: *anchor\n") do |path|
        assert_nil ShapeContract.definition(path, "docs"), "a YAML merge key (Psych::AliasesNotEnabled)"
      end
      with_config("just a scalar\n") do |path|
        assert_nil ShapeContract.definition(path, "docs"), "a non-Hash document root (NoMethodError)"
      end
    end
  end

  # THE REAL TAXONOMY, not a fixture. This is the claim the whole change rests on, and
  # it must break here if someone edits the `docs` stanza rather than being discovered
  # by a builder mid-ship.
  def test_the_real_docs_shape_owes_no_suite_and_every_code_shape_does
    refute ShapeContract.suite_owed?(ShapeContract.definition(REAL_SHAPES, "docs")),
           "config/feature_shapes.yml's `docs` stanza is what this waiver reads"

    %w[ui-only ui+db backend library onchain onchain-vertical test-only].each do |shape|
      assert ShapeContract.suite_owed?(ShapeContract.definition(REAL_SHAPES, shape)),
             "#{shape} must keep owing a cert — `test-only` especially: it has NO tiers but " \
             "declares full_suite_gate: true precisely because test code IS code"
    end
  end

  # --- cert_waiver — the DECLARATION *and* the OBSERVATION ------------------------

  NO_SUITE = { "full_suite_gate" => false, "dor_tiers" => [] }.freeze

  def waiver(shape: "docs", shape_def: NO_SUITE, changed: ["docs/note.md"])
    ShapeContract.cert_waiver(shape: shape, shape_def: shape_def, changed: changed)
  end

  def test_a_no_suite_shape_over_a_prose_diff_is_waived
    found = waiver(changed: ["docs/agents/note.md", "docs/img/flow.png", "README.md"])

    refute_nil found
    assert_equal "docs", found[:shape]
    assert_equal 3, found[:files].size
  end

  # THE OBSERVATION IS THE SAFETY. Every case below carries the `docs` LABEL and is
  # refused anyway — which is the property that separates this waiver from the bug
  # family it sits in (a `kind` label, a `docs/` directory, a `docs` shape: each a
  # claim ABOUT a change standing in for evidence OF it).
  def test_one_behavioral_file_kills_the_waiver_however_the_task_is_shaped
    assert_nil waiver(changed: ["docs/note.md", "app/models/task.rb"]),
               "the PR #1172 shape: a docs-SHAPED diff carrying production code"
    assert_nil waiver(changed: ["docs/note.md", "test/docs/sop_registry_docs_test.rb"]),
               "a test file is executable — and a DELETED guard test is exactly the change " \
               "that needs a suite, which is why this gate uses doc_only? not docs_with_guards?"
    assert_nil waiver(changed: ["docs/agents/setup.sh"]),
               "location buys nothing: docs/agents/setup.sh is mode 100755"
    assert_nil waiver(changed: [".github/workflows/ci.yml"]),
               "the PR #512 shape: a workflow change is behaviour"
    assert_nil waiver(changed: ["config/feature_shapes.yml"]),
               "a comment-only edit to a .yml is still a .yml — the granularity is the FILE"
  end

  # AN EMPTY LIST IS NOT A PROSE DIFF. "We observed nothing" and "there is nothing but
  # prose" are different facts, and collapsing them is how a blind checkout grants a
  # waiver — the same line CodeDiff.doc_only? and TestOnlyDiff.test_only? draw.
  def test_an_unobservable_diff_is_never_waived
    assert_nil waiver(changed: [])
    assert_nil waiver(changed: nil)
    assert_nil waiver(changed: ["", "   "])
  end

  def test_a_shape_that_owes_a_suite_is_never_waived_however_prose_the_diff
    assert_nil waiver(shape: "backend", shape_def: { "dor_tiers" => %w[unit integration] })
    assert_nil waiver(shape: "docs", shape_def: nil), "an unreadable stanza owes a suite"
    assert_nil waiver(shape: "", shape_def: NO_SUITE), "no shape on the task, no waiver"
    assert_nil waiver(shape: nil, shape_def: NO_SUITE)
  end

  # --- the message ---------------------------------------------------------------
  #
  # A reader must not be able to mistake this for a cert. The line is the only thing
  # standing between "no suite was owed" and "the cert passed", and those are very
  # different claims about the same exit code.
  def test_the_message_says_it_is_not_a_cert_and_names_both_facts
    message = waiver(changed: ["docs/note.md"])[:message]

    assert_match(/NO CERT OWED/, message)
    assert_match(/NOTHING is recorded/, message)
    assert_match(/full_suite_gate/, message, "names the DECLARATION it read")
    assert_match(/OBSERVED diff/, message, "names the OBSERVATION that made it safe")
    assert_match(%r{docs/note\.md}, message, "names the files, so the waiver can be checked")
    refute_match(/fast cert green/, message, "must never read as the green-cert line")
  end

  def test_the_message_truncates_a_long_file_list_rather_than_flooding_the_terminal
    files = (1..20).map { |i| "docs/note#{i}.md" }
    message = waiver(changed: files)[:message]

    assert_match(/\+14 more/, message)
    assert_match(/20 file\(s\)/, message, "the COUNT is never truncated, only the listing")
  end
end

# frozen_string_literal: true

# Standalone unit test for bin/lib/control_replay.rb — the PURE half of the
# `test-only` shape's executed control (no git, no Rails). Run directly:
#   ruby -Itest test/lib/control_replay_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/control_replay"

class ControlReplayTest < Minitest::Test
  # --- parse_name_status ------------------------------------------------------

  def test_parses_modify_add_and_delete
    changes = ControlReplay.parse_name_status(
      "M\ttest/models/a_test.rb\nA\ttest/models/b_test.rb\nD\ttest/models/c_test.rb\n"
    )
    assert_equal %w[M A D], changes.map(&:status)
    # The single fact the whole partition turns on: did this path exist at the base?
    assert_equal "test/models/a_test.rb", changes[0].old_path
    assert_nil changes[1].old_path
    assert_equal "test/models/c_test.rb", changes[2].old_path
  end

  def test_rename_row_carries_the_old_path_forward
    changes = ControlReplay.parse_name_status("R100\ttest/models/old_test.rb\ttest/models/new_test.rb\n")
    change = changes.fetch(0)
    assert_equal "R", change.status
    assert_equal "test/models/new_test.rb", change.path
    assert_equal "test/models/old_test.rb", change.old_path,
                 "a rename HAS a pre-change version — at the old path — and losing it is what would " \
                 "misclassify a rename as unreplayable"
  end

  def test_copy_destination_has_no_pre_change_version
    # A copy's SOURCE is untouched; only the destination is new content. Treating
    # the source as the destination's "pre-change version" would replay a file the
    # diff never changed and report a verdict about the wrong thing.
    changes = ControlReplay.parse_name_status("C075\ttest/models/src_test.rb\ttest/models/dst_test.rb\n")
    assert_nil changes.fetch(0).old_path
  end

  def test_ignores_malformed_and_blank_rows
    assert_empty ControlReplay.parse_name_status("\n   \nM\n")
  end

  # --- runnable? --------------------------------------------------------------

  def test_runnable_is_ruby_minitest_files_only
    assert ControlReplay.runnable?("test/models/a_test.rb")
    assert ControlReplay.runnable?("test/integration/deep/nested_test.rb")
  end

  def test_support_files_under_test_are_not_runnable
    # These live under a test root (so `test-only` claims them, correctly) but none
    # is a runnable unit. Calling them runnable would produce a run that executed
    # NOTHING and a green verdict from it — the failure mode this module guards
    # hardest against.
    refute ControlReplay.runnable?("test/test_helper.rb")
    refute ControlReplay.runnable?("test/fixtures/tasks.yml")
    refute ControlReplay.runnable?("test/support/session_env.rb")
  end

  def test_other_test_roots_have_no_runner_here
    # Replayable in PRINCIPLE (they have pre-change versions), but Playwright needs
    # a booted server and Anchor a funded validator. Named as deferred rather than
    # silently counted — the e2e_onchain lesson.
    refute ControlReplay.runnable?("e2e/upload.spec.js")
    refute ControlReplay.runnable?("tests/turf_vault.ts")
  end

  # --- partition --------------------------------------------------------------

  def test_partition_splits_the_three_populations
    changes = ControlReplay.parse_name_status([
      "M\ttest/models/a_test.rb",    # replayable
      "D\ttest/models/b_test.rb",    # replayable (existed at base)
      "A\ttest/models/c_test.rb",    # added — nothing to replay, ever
      "M\te2e/upload.spec.js",       # deferred — no runner here
      "M\ttest/fixtures/tasks.yml"   # deferred — not a runnable unit
    ].join("\n"))

    parts = ControlReplay.partition(changes)
    assert_equal ["test/models/a_test.rb", "test/models/b_test.rb"], parts[:replay]
    assert_equal ["e2e/upload.spec.js", "test/fixtures/tasks.yml"], parts[:deferred]
    assert_equal ["test/models/c_test.rb"], parts[:added]
  end

  def test_partition_replays_a_rename_through_its_old_path
    changes = ControlReplay.parse_name_status("R100\ttest/models/old_test.rb\ttest/models/new_test.rb")
    assert_equal ["test/models/old_test.rb"], ControlReplay.partition(changes)[:replay]
  end

  def test_partition_output_is_sorted_and_deduped
    changes = ControlReplay.parse_name_status("M\ttest/models/z_test.rb\nM\ttest/models/a_test.rb")
    assert_equal ["test/models/a_test.rb", "test/models/z_test.rb"], ControlReplay.partition(changes)[:replay]
  end

  # --- head_runnable ----------------------------------------------------------

  def test_head_runnable_excludes_deleted_files
    changes = ControlReplay.parse_name_status(
      "M\ttest/models/a_test.rb\nD\ttest/models/b_test.rb\nA\ttest/models/c_test.rb"
    )
    # A deleted file has no post-change version to run; asking `bin/rails test` for
    # a path that no longer exists is an error, not a red test.
    assert_equal ["test/models/a_test.rb", "test/models/c_test.rb"], ControlReplay.head_runnable(changes)
  end

  def test_head_runnable_uses_the_new_path_of_a_rename
    changes = ControlReplay.parse_name_status("R100\ttest/models/old_test.rb\ttest/models/new_test.rb")
    assert_equal ["test/models/new_test.rb"], ControlReplay.head_runnable(changes)
  end

  # --- verdict ----------------------------------------------------------------

  def test_old_red_is_necessary
    assert_equal ControlReplay::NECESSARY, ControlReplay.verdict(old_failed: true, head_failed: false)
  end

  def test_old_green_is_no_signal
    # The pre-change test PASSED against unchanged production code, so the replay
    # distinguishes nothing. This is what a rename, a move, a consolidation AND a
    # silently-deleted assertion all look like.
    assert_equal ControlReplay::NO_SIGNAL, ControlReplay.verdict(old_failed: false, head_failed: false)
  end

  def test_head_red_outranks_the_comparison
    assert_equal ControlReplay::HEAD_RED, ControlReplay.verdict(old_failed: true, head_failed: true)
    assert_equal ControlReplay::HEAD_RED, ControlReplay.verdict(old_failed: false, head_failed: true)
  end

  # --- verdict_of (the writer/reader round trip) ------------------------------

  def test_verdict_round_trips_through_a_stamped_line
    # The property that matters: what bin/control-check WRITES, bin/dor-check can
    # READ. A drift here silently disables the NO-SIGNAL follow-up question.
    ControlReplay::VERDICTS.each do |token|
      detail = ControlReplay.detail(verdict: token, replay: ["test/models/a_test.rb"],
                                    deferred: [], added: [], old_failed: true, head_failed: false)
      line = "[#{ControlReplay::LANE}@abc1234] #{detail}"
      assert_equal token, ControlReplay.verdict_of(line), "verdict #{token} did not survive the round trip"
    end
  end

  def test_verdict_of_is_nil_when_no_token_present
    assert_nil ControlReplay.verdict_of("[control@abc1234] ran something")
  end

  # --- detail -----------------------------------------------------------------

  def test_detail_names_the_replayed_files
    # dor-check's existing "the control names a file from this diff" check reads
    # this text, so the stamp must satisfy it without the author retyping the path.
    detail = ControlReplay.detail(verdict: ControlReplay::NECESSARY, replay: ["test/models/a_test.rb"],
                                  deferred: [], added: [], old_failed: true, head_failed: false)
    assert_includes detail, "test/models/a_test.rb"
  end

  def test_detail_reports_deferred_and_added_rather_than_hiding_them
    detail = ControlReplay.detail(verdict: ControlReplay::NECESSARY, replay: ["test/models/a_test.rb"],
                                  deferred: ["e2e/upload.spec.js"], added: ["test/models/c_test.rb"],
                                  old_failed: true, head_failed: false)
    assert_includes detail, "DEFERRED"
    assert_includes detail, "e2e/upload.spec.js"
    assert_includes detail, "ADDED"
    assert_includes detail, "test/models/c_test.rb"
  end

  def test_no_signal_detail_says_the_replay_proves_nothing
    detail = ControlReplay.detail(verdict: ControlReplay::NO_SIGNAL, replay: ["test/models/a_test.rb"],
                                  deferred: [], added: [], old_failed: false, head_failed: false)
    assert_includes detail, "distinguishes nothing"
  end

  def test_detail_states_red_green_rather_than_inventing_a_count
    # The runner's authority is the test process's EXIT STATUS. Rendering that as
    # "1 failure(s)" would publish a number nothing measured.
    detail = ControlReplay.detail(verdict: ControlReplay::NECESSARY, replay: ["test/models/a_test.rb"],
                                  deferred: [], added: [], old_failed: true, head_failed: false)
    assert_includes detail, "pre-change RED"
    assert_includes detail, "post-change GREEN"
    refute_includes detail, "failure(s)"
  end

  # --- the lane is machine-owned ----------------------------------------------

  def test_lane_is_registered_as_machine_owned_evidence
    # Registration is what stops an author's `--checks` update from wiping the
    # stamp (lib/cert_evidence.rb's write rule) — and a wiped stamp sends the
    # builder back to re-run, which is how people learn to hand-write evidence.
    assert_includes CertEvidence::EVIDENCE_LANES, ControlReplay::LANE
    refute_includes CertEvidence::LANES, ControlReplay::LANE,
                    "the control must NOT be a full-cert lane — that would demand a control of every shape, " \
                    "including the ones with no test-only diff to replay"
  end
end

# frozen_string_literal: true

# Unit + integration tests for test/minitest/ci_receipt_plugin.rb — THE RECEIPT ITSELF.
#
# The receipt is the evidence bin/rails-executed-set-check judges the sharded lane on.
# If it can be lost, overwritten, or silently not produced, the gate's arithmetic is
# arithmetic over the wrong numbers — so the mechanism gets the same scrutiny as the
# gate that reads it.
#
# THE INTEGRATION TESTS BELOW SPAWN REAL `bin/rails test` CHILD PROCESSES, and that is
# deliberate rather than lazy. The failure they pin — a subprocess inheriting
# CI_RECEIPT_OUT and writing its own receipt over the parent's — cannot be reproduced by
# calling methods, because it is entirely about process boundaries and environment
# inheritance. It was found by RUNNING the suite (the receipt came out holding 11 results
# instead of 6,828) and it can only be pinned the same way.
#
# Run directly:
#   ruby -Itest test/lib/ci_receipt_plugin_test.rb
#
# Two tiers (backend shape):
#   [unit] the plugin's enable/attribute/aggregate logic, in-process.
#   [integration] a real spawned `bin/rails test` child against a live parent receipt.

require "minitest/autorun"
require "tmpdir"
require "json"
require "open3"
require_relative "../../test/minitest/ci_receipt_plugin"

class CiReceiptPluginTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # A tiny, DB-free suite to hand a child process. It lives in a tmpdir rather than under
  # test/ on purpose: a `_test.rb` inside the tree would join the sharded lane's manifest,
  # and bin/rails-executed-set-check would then demand a shard run a fixture that exists
  # only to be spawned.
  FIXTURE = <<~RUBY_FIXTURE
    require "minitest/autorun"
    class SpawnedChildFixtureTest < Minitest::Test
      def test_child_one; assert true; end
      def test_child_two; assert true; end
    end
  RUBY_FIXTURE

  def setup
    @saved_env = ENV.to_h.slice("CI_RECEIPT_OUT", "CI_RECEIPT_SHARD", "CI_RECEIPT_SHARD_TOTAL", "CI_RECEIPT_ROOT", "CI_RECEIPT_OWNER_PID", "CI_RECEIPT_COMMIT")
  end

  def teardown
    %w[CI_RECEIPT_OUT CI_RECEIPT_SHARD CI_RECEIPT_SHARD_TOTAL CI_RECEIPT_ROOT CI_RECEIPT_OWNER_PID CI_RECEIPT_COMMIT].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
  end

  # ---- [unit] the switch --------------------------------------------------------

  def test_unit_the_plugin_is_inert_without_an_output_path
    refute CiReceipt.enabled?({}), "a local `bin/rails test` must pay for none of this"
    refute CiReceipt.enabled?({ "CI_RECEIPT_OUT" => "  " }), "a blank path is not a path"
  end

  def test_unit_the_first_process_to_ask_stamps_itself_as_the_owner
    env = { "CI_RECEIPT_OUT" => "/tmp/x.json" }

    assert CiReceipt.enabled?(env)
    assert_equal Process.pid.to_s, env["CI_RECEIPT_OWNER_PID"],
                 "the owner stamp must be written into the env so CHILDREN inherit it"
  end

  def test_unit_a_process_that_is_not_the_owner_stands_down
    # THE CLOBBER GUARD, as a unit. A child inherits CI_RECEIPT_OUT *and* the parent's
    # owner stamp; its own pid does not match, so it records nothing and writes nothing.
    env = { "CI_RECEIPT_OUT" => "/tmp/x.json", "CI_RECEIPT_OWNER_PID" => (Process.pid + 1).to_s }

    refute CiReceipt.enabled?(env)
  end

  def test_unit_the_owner_stays_enabled_on_repeated_asks
    env = { "CI_RECEIPT_OUT" => "/tmp/x.json" }

    assert CiReceipt.enabled?(env)
    assert CiReceipt.enabled?(env), "the owner must not stand itself down on the second call"
  end

  # ---- [unit] attribution and aggregation ---------------------------------------
  #
  # EVERY CASE BELOW BUILDS ITS OWN Recorder. That is not style — it is the fix for the
  # bug this file caused. These tests used to poke at module-level constants
  # (CiReceipt::FILES.clear between cases), and when they ran INSIDE a real shard they
  # wiped that shard's live receipt: shard 4 of the proof run executed 1,517 tests across
  # 116 files and emitted a receipt claiming 1 file and 3 runs. The executed-set gate is
  # what caught it. A process-wide mutable accumulator is reachable by anything in the
  # process, and a test suite is the one program guaranteed to contain code that reaches.

  Result = Struct.new(:klass, :name, :assertions, :time, :failures, :source_location)

  def result(file:, name: "test_x", assertions: 2, time: 0.25, failures: [])
    Result.new("SomeTest", name, assertions, time, failures, [ file, 1 ])
  end

  def recorder
    CiReceipt::Recorder.new(root: ROOT)
  end

  def test_unit_the_plugin_exposes_no_shared_mutable_accumulator
    # THE REGRESSION GUARD for the bug above. The counters must not be reachable as
    # module state; if a refactor puts them back, any test that clears them can silently
    # shrink a live shard's receipt again, and the only symptom is a gate failure two
    # jobs later blaming 115 innocent files.
    %i[FILES UNATTRIBUTED RESULTS].each do |name|
      refute CiReceipt.const_defined?(name, false),
             "CiReceipt::#{name} is module-level mutable state. The receipt's counters must " \
             "live on a Recorder instance the plugin owns, so nothing else in the process — " \
             "least of all this suite — can reach the run's accumulator."
    end
  end

  def test_unit_the_defining_file_is_recorded_repo_relative
    assert_equal "test/models/a_test.rb",
                 CiReceipt.file_for(result(file: File.join(ROOT, "test/models/a_test.rb")), root: ROOT)
  end

  def test_unit_a_file_outside_the_root_keeps_its_absolute_path
    # Never silently re-rooted: a path the gate cannot match is better than a path it
    # matches WRONGLY.
    assert_equal "/elsewhere/x_test.rb", CiReceipt.file_for(result(file: "/elsewhere/x_test.rb"), root: ROOT)
  end

  def test_unit_a_result_with_no_resolvable_file_is_carried_as_unattributed
    rec = recorder
    rec.record(Result.new("GhostTest", "test_x", 1, 0.1, [], nil))

    assert_empty rec.files
    assert_equal [ "GhostTest#test_x" ], rec.unattributed,
                 "an unattributable test must be CARRIED, not dropped — the gate refuses a receipt " \
                 "that has any, because the arithmetic below it would be unsound"
  end

  def test_unit_results_aggregate_per_file
    rec = recorder
    path = File.join(ROOT, "test/models/a_test.rb")

    rec.record(result(file: path, name: "test_one", time: 0.25))
    rec.record(result(file: path, name: "test_two", time: 0.75))

    row = rec.files.fetch("test/models/a_test.rb")
    assert_equal 2, row["runs"]
    assert_equal 4, row["assertions"]
    assert_in_delta 1.0, row["seconds"], 0.001
  end

  def test_unit_a_skip_counts_as_a_run_and_as_a_skip
    # It RAN — the file is covered — and the skip is separately visible to the ceiling in
    # config/rails_lane.yml. Counting a skip as "did not run" would make a suite that
    # skips everything indistinguishable from one that runs nothing.
    rec = recorder
    path = File.join(ROOT, "test/models/a_test.rb")
    rec.record(result(file: path, failures: [ Minitest::Skip.new("nope") ]))

    row = rec.files.fetch("test/models/a_test.rb")
    assert_equal 1, row["runs"]
    assert_equal 1, row["skips"]
    assert_equal 0, row["failures"]
  end

  def test_unit_two_recorders_do_not_share_state
    # The property that makes the whole class of bug impossible, asserted directly.
    first = recorder
    first.record(result(file: File.join(ROOT, "test/models/a_test.rb")))

    assert_empty recorder.files, "a fresh Recorder must not see another Recorder's results"
    assert_equal 1, first.files.size
  end

  def test_unit_the_payload_totals_the_rows
    rec = recorder
    rec.record(result(file: File.join(ROOT, "test/models/a_test.rb"), assertions: 3))
    rec.record(result(file: File.join(ROOT, "test/models/b_test.rb"), assertions: 4))

    totals = rec.payload({ "CI_RECEIPT_SHARD" => "2", "CI_RECEIPT_SHARD_TOTAL" => "4" })["totals"]
    assert_equal 2, totals["files"]
    assert_equal 2, totals["runs"]
    assert_equal 7, totals["assertions"]
  end

  # ---- the commit the shard ran, and why the receipt has to carry it -------------
  #
  # The executed-set gate re-derives the expected file set from a tree it checks out
  # ITSELF, which in the consumer lane is a BRANCH NAME resolved minutes after the
  # shards resolved theirs. Engine run 32495361932 is the measured case: hub PR #979
  # merged f9a440e5 in the four minutes between the two checkouts, and the gate reported
  # the two files it added as committed files that "executed NOTHING". They had run green
  # in the hub's own lane; they simply had not existed when the shards checked out. The
  # receipt is the only place that fact can be recorded, because it is the only artifact
  # that crosses from the shard to the gate.

  def test_unit_the_payload_names_the_commit_the_shard_ran
    rec = recorder
    rec.record(result(file: File.join(ROOT, "test/models/a_test.rb")))

    payload = rec.payload({ "CI_RECEIPT_SHARD" => "2", "CI_RECEIPT_SHARD_TOTAL" => "4",
                            "CI_RECEIPT_COMMIT" => "f9a440e5" })

    assert_equal "f9a440e5", payload["commit"]
  end

  # THE LOAD-BEARING PATH. The consumer lane runs `bundle exec rails test $(bin/ci-shard
  # --print …)` rather than bin/ci-shard itself, so nothing upstream sets
  # CI_RECEIPT_COMMIT there — and the consumer lane is exactly the one whose checkout can
  # drift from the gate's. If the fallback ever stopped resolving, the field would go
  # quietly blank and the race would become invisible again.
  def test_unit_the_commit_falls_back_to_the_git_head_of_the_root
    payload = CiReceipt::Recorder.new(root: ROOT).payload({})

    assert_match(/\A[0-9a-f]{40}\z/, payload["commit"],
                 "with no CI_RECEIPT_COMMIT the recorder must read HEAD out of its own root")
  end

  # "Could not tell" must be an empty string, never a guess: the gate reads a blank
  # commit as SILENCE and audits strictly, whereas a wrong SHA would manufacture a
  # mismatch and turn every run of a non-git tree red.
  def test_unit_a_root_outside_a_repository_names_no_commit
    Dir.mktmpdir do |dir|
      assert_equal "", CiReceipt::Recorder.new(root: dir).payload({})["commit"]
    end
  end

  # ---- [integration] the real process boundary ----------------------------------

  # Spawn a real `bin/rails test` child against a throwaway fixture.
  #
  # `CI_RECEIPT_OWNER_PID => nil` IS LOAD-BEARING, and its absence is a bug this file
  # already shipped once. Open3 MERGES the given hash into the parent's environment
  # rather than replacing it — so when these tests run INSIDE a real shard (where the
  # shard has stamped its own pid as the owner) the child inherited that stamp, stood
  # down, and wrote nothing. The "the owner DOES write one" case then failed, but ONLY
  # in place: standalone the variable is unset and everything passed. A nil value tells
  # Process.spawn to UNSET the variable in the child, which makes the two contexts agree.
  #
  # Callers that want the child to see an owner pass one explicitly.
  def run_child(env)
    Dir.mktmpdir do |dir|
      fixture = File.join(dir, "spawned_child_fixture_test.rb")
      File.write(fixture, FIXTURE)
      receipt = File.join(dir, "receipt.json")

      child_env = { "CI_RECEIPT_OWNER_PID" => nil }
                  .merge(env)
                  .merge("CI_RECEIPT_OUT" => receipt, "CI_RECEIPT_ROOT" => dir)

      _out, _err, status = Open3.capture3(
        child_env,
        File.join(ROOT, "bin", "rails"), "test", fixture,
        chdir: ROOT
      )

      yield receipt, status
    end
  end

  def test_integration_a_spawned_child_does_not_clobber_the_parents_receipt
    # THE BUG, PINNED WHERE IT LIVES. test/commands/* drive bin/fast-check and
    # bin/agent-worktree, which shell out to `bin/rails test`. Those children inherit the
    # whole environment, CI_RECEIPT_OUT included — and before the owner-pid guard, the
    # LAST one to exit wrote its own tiny receipt over the shard's. Measured on a full
    # local run: 11 results in the file instead of 6,828.
    #
    # Here THIS process is the owner (it stamps its own pid), and the child inherits that
    # stamp. A child that respects it writes nothing at all.
    run_child("CI_RECEIPT_OWNER_PID" => Process.pid.to_s) do |receipt, status|
      assert status.success?, "the child suite itself should pass"
      refute File.exist?(receipt),
             "a spawned child wrote a receipt while another process owned it — the shard's receipt " \
             "would have been overwritten by the child's, and the executed-set gate would report the " \
             "child's two tests as the shard's whole coverage"
    end
  end

  def test_integration_a_process_that_owns_the_receipt_does_write_it
    # THE OTHER DIRECTION, and the reason the test above is not vacuous: with no owner
    # stamp inherited, the child IS the owner and must produce a receipt. Without this,
    # a plugin that never loaded at all would pass the clobber test perfectly.
    run_child({}) do |receipt, status|
      assert status.success?
      assert File.exist?(receipt), "the owning process must write its receipt"

      payload = JSON.parse(File.read(receipt))
      assert_equal 2, payload.dig("totals", "runs")
      assert_equal [ "spawned_child_fixture_test.rb" ], payload["files"].keys
      assert_empty payload["unattributed"]
    end
  end
end

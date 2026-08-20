# frozen_string_literal: true

# test/minitest/ci_receipt_plugin.rb — the RAILS LANE'S RECEIPT.
#
# WHAT IT IS FOR. The sharded `rails` job can prove its tests PASSED; it cannot
# prove it RAN THEM ALL — no test lane can answer that about itself. That is the
# same blind spot the `playwright` lane has, and the same answer applies: each
# shard emits a machine-readable receipt of what it actually executed, and a
# SEPARATE job (`bin/rails-executed-set-check`, the `rails_executed_set` gate)
# does the arithmetic against the committed tree.
#
# Why a receipt rather than another guard clause: test/lib/ci_workflow_triggers_test.rb
# guards the suite command by ENUMERATING the ways it could be narrowed — TEST,
# TESTOPTS, DEFAULT_TEST, DEFAULT_TEST_EXCLUDE, a job `if:`, a heredoc GITHUB_ENV
# write. Its own header says the right instinct is not "the class is closed" but
# "here is where I would look next", and it names a live hole (a heredoc write from
# an EARLIER step). A blacklist can only refuse the spellings someone thought to
# refuse. This reads the EXECUTED set instead, so a file that leaves the lane by ANY
# route — a flag invented next year, a shard that silently ran nothing, a bin-packing
# bug that assigned it to no shard at all — lands on the same line of arithmetic.
#
# HOW IT LOADS. Minitest discovers plugins by scanning the load path for
# `minitest/*_plugin.rb` (Minitest.load_plugins -> Gem.find_files). Rails' test
# runner puts `test/` on $LOAD_PATH, and the bare minitest files under test/lib and
# test/commands reach it through `minitest/autorun`. So this file is picked up by
# BOTH halves of the suite without either having to require anything — which is the
# point: a receipt that only sees the files that opted in would certify the opt-in,
# not the suite.
#
# INERT UNLESS ASKED. It records nothing and writes nothing unless CI_RECEIPT_OUT
# names an output path, so a local `bin/rails test` pays for none of it.
#
# ⚠️ THE OWNER-PID GUARD, AND WHY IT IS NOT OPTIONAL. Several suites here SPAWN a
# subprocess that itself runs minitest — test/commands/* drive bin/fast-check and
# bin/agent-worktree, which shell out to `bin/rails test`. A subprocess inherits the
# whole environment, CI_RECEIPT_OUT included, so its own minitest run would load this
# plugin and WRITE OVER the parent's receipt at exit. That is not theoretical: measured
# on a full local run, the receipt file ended up holding 11 results instead of 6,828 —
# a child's whole suite masquerading as the parent's. The gate would then read a receipt
# missing 99% of the lane and call CI red for a reason no one could find.
#
# So the FIRST process to initialise stamps its own pid into the environment, and a
# process whose pid does not match it disables itself. The stamp is inherited, so every
# descendant sees a foreign owner and stands down; the owner sees itself and records.
# Rails' parallel workers are forks that never re-enter Minitest.run, and they would be
# stood down by the same rule if they ever did. Pinned by
# test/lib/ci_receipt_plugin_test.rb#test_integration_a_spawned_child_does_not_clobber_the_parents_receipt,
# which spawns a real child and asserts the parent's receipt survives intact.
#
# PARALLEL-SAFE. Rails' parallel workers report results back to the PARENT process's
# reporter over DRb, so `record` runs in the parent and one receipt covers every
# worker. Pinned by test/lib/ci_receipt_plugin_test.rb, which runs a real forked
# parallel suite rather than asserting the claim.

require "json"

module CiReceipt
  OWNER_KEY = "CI_RECEIPT_OWNER_PID"

  # THE ACCUMULATOR IS AN OBJECT, NOT A CONSTANT — and that is a bug fix, not taste.
  #
  # The first version of this file held the counters in module-level constants
  # (CiReceipt::FILES, CiReceipt::UNATTRIBUTED). Its own unit tests then did the obvious
  # thing and called `FILES.clear` between cases — which, when those tests ran INSIDE a
  # real shard, wiped the shard's live receipt. Measured: shard 4 of the proof run
  # recorded 1,517 tests across 116 files and emitted a receipt claiming ONE file and
  # THREE runs. The executed-set gate caught it (115 files "executed NOTHING"), which is
  # the system working, but the shape is worth naming: a process-wide mutable global is
  # reachable by anything in the process, and a test suite is the one program guaranteed
  # to contain code that pokes at internals.
  #
  # So the state lives in a Recorder the plugin creates and only the reporter closure
  # holds. Tests construct their OWN Recorder and cannot reach this run's.
  # test/lib/ci_receipt_plugin_test.rb additionally refuses the constants by name, so the
  # global cannot come back by a well-meaning refactor.
  class Recorder
    attr_reader :files, :unattributed

    def initialize(root: Dir.pwd)
      @root = root
      @files = Hash.new { |h, k| h[k] = { "runs" => 0, "assertions" => 0, "failures" => 0, "errors" => 0, "skips" => 0, "seconds" => 0.0 } }
      # Tests whose defining file could not be resolved. NEVER silently dropped — an
      # unattributable test is a hole in the arithmetic, so it is carried into the
      # receipt and the gate refuses a receipt that has any.
      @unattributed = []
    end

    def record(result)
      file = CiReceipt.file_for(result, root: @root)
      if file.nil?
        @unattributed << "#{result.klass}##{result.name}"
        return
      end

      row = @files[file]
      row["runs"] += 1
      row["assertions"] += result.assertions.to_i
      row["seconds"] = (row["seconds"] + result.time.to_f).round(4)
      row["failures"] += 1 if CiReceipt.failure?(result)
      row["errors"] += 1 if CiReceipt.error?(result)
      row["skips"] += 1 if CiReceipt.skipped?(result)
    end

    def payload(env = ENV)
      totals = @files.each_value.with_object({ "files" => @files.size, "runs" => 0, "assertions" => 0, "failures" => 0, "errors" => 0, "skips" => 0, "seconds" => 0.0 }) do |row, acc|
        acc["runs"] += row["runs"]
        acc["assertions"] += row["assertions"]
        acc["failures"] += row["failures"]
        acc["errors"] += row["errors"]
        acc["skips"] += row["skips"]
        acc["seconds"] = (acc["seconds"] + row["seconds"]).round(4)
      end

      {
        "shard" => env["CI_RECEIPT_SHARD"].to_s,
        "shards" => env["CI_RECEIPT_SHARD_TOTAL"].to_s,
        "files" => @files.sort.to_h,
        "totals" => totals,
        "unattributed" => @unattributed.sort
      }
    end

    def dump!(env = ENV)
      path = CiReceipt.out_path(env)
      return if path.nil?

      dir = File.dirname(path)
      Dir.mkdir(dir) unless dir == "." || Dir.exist?(dir)
      File.write(path, JSON.pretty_generate(payload(env)))
      warn "[ci-receipt] #{@files.size} files, #{payload(env)["totals"]["runs"]} runs -> #{path}"
    rescue StandardError => e
      # A receipt that cannot be written must NOT be silent: the gate treats a missing
      # receipt as a failure, but say why here so the log names the cause.
      warn "[ci-receipt] FAILED to write #{path}: #{e.class}: #{e.message}"
    end
  end

  class Reporter < Minitest::AbstractReporter
    def initialize(recorder)
      super()
      @recorder = recorder
    end

    def record(result)
      @recorder.record(result)
    end
  end

  class << self
    def out_path(env = ENV)
      path = env["CI_RECEIPT_OUT"].to_s.strip
      path.empty? ? nil : path
    end

    def enabled?(env = ENV)
      return false if out_path(env).nil?

      owner = env[OWNER_KEY].to_s.strip
      if owner.empty?
        env[OWNER_KEY] = Process.pid.to_s
        return true
      end

      owner == Process.pid.to_s
    end

    # The repo-relative path a result was defined in. Minitest's `source_location` is
    # authoritative when present; the instance-method lookup is the fallback for results
    # that do not carry one (a skip raised before the body, notably).
    def file_for(result, root: Dir.pwd)
      raw = begin
        loc = result.source_location
        loc && loc[0]
      rescue StandardError
        nil
      end
      raw ||= begin
        Object.const_get(result.klass.to_s).instance_method(result.name).source_location&.first
      rescue StandardError
        nil
      end
      return nil if raw.nil?

      relative(raw, root)
    end

    def relative(path, root = Dir.pwd)
      absolute = File.expand_path(path)
      prefix = File.join(File.expand_path(root), "")
      absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : absolute
    end

    def failure?(result)
      result.failures.any? { |f| f.is_a?(Minitest::Assertion) && !f.is_a?(Minitest::Skip) }
    end

    def error?(result)
      result.failures.any? { |f| f.is_a?(Minitest::UnexpectedError) }
    end

    def skipped?(result)
      result.failures.any? { |f| f.is_a?(Minitest::Skip) }
    end
  end
end

module Minitest
  def self.plugin_ci_receipt_options(opts, options); end

  def self.plugin_ci_receipt_init(_options)
    return unless CiReceipt.enabled?

    recorder = CiReceipt::Recorder.new(root: ENV.fetch("CI_RECEIPT_ROOT", Dir.pwd))
    reporter << CiReceipt::Reporter.new(recorder)
    Minitest.after_run { recorder.dump! }
  end
end

# frozen_string_literal: true

# [integration] A sample of the scripts PRINT their remedy hints through Remedy.
#
# test/lib/remedy_test.rb pins the helper. A correct helper the scripts never call
# fixes nothing, so this file runs real scripts (or calls the composers they speak
# through) and asks the DISK about each printed command: is the script absolute, and
# is it an executable. A substring assertion is blind here, because an absolute path
# contains the bare `bin/<script>` form (measured on PR #1341).
#
# Every run is read-only: `agent-worktree whereami` from an empty dir, `qa-intake`
# against a registry that does not exist, and `submit` refused by another session's
# dirty desk before it roots.
#
#   ruby -Itest test/lib/remedy_hints_reach_the_reader_test.rb

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/fake_desk"
require_relative "../../bin/lib/remedy"

class RemedyHintsReachTheReaderTest < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  BIN = File.join(REPO, "bin")

  # Each composer's remedy constant: the module, the constant, and the script it must
  # name. These are the strings bin/dor-check, bin/submit, bin/task, bin/reviewer-select,
  # bin/task review-claim and the archive guard interpolate into their refusals.
  COMPOSED = [
    ["bin/lib/ci_gate.rb", "CiGate", "TASK_CMD", "task"],
    ["bin/lib/ci_status.rb", "CiStatus", "GH_AUTH_REFRESH_CMD", "gh-auth-refresh"],
    ["bin/lib/block_recipe.rb", "BlockRecipe", "TASK_CMD", "task"],
    ["lib/claim_holder.rb", "ClaimHolder", "TASK_COMMAND", "task"],
    ["bin/lib/review_claim_cli.rb", "ReviewClaimCli", "TASK_CMD", "task"],
    ["bin/lib/review_worker_pulse.rb", "ReviewWorkerPulse", "TASK_CMD", "task"],
    ["bin/lib/reviewer_select_skip.rb", "ReviewerSelectSkip", "TASK_CMD", "task"],
    ["bin/lib/approval_request_notice.rb", "ApprovalRequestNotice", "TASK_CMD", "task"],
    ["lib/open_pr_guard.rb", "OpenPrGuard", "TASK_CMD", "task"]
  ].freeze

  def test_every_composed_remedy_constant_is_the_helpers_rendering
    COMPOSED.each do |rel, mod_name, const, script|
      require File.join(REPO, rel.sub(/\.rb\z/, ""))
      value = Object.const_get(mod_name).const_get(const)

      assert_equal Remedy.command(script, BIN), value, "#{mod_name}::#{const} was not built by Remedy.command"
      assert_runnable value, "#{mod_name}::#{const}"
    end
  end

  def test_a_composed_refusal_hands_over_the_absolute_command
    require File.join(REPO, "bin/lib/reviewer_select_skip")
    require File.join(REPO, "lib/desk_database_guard")
    require File.join(REPO, "lib/seam_reconcile")

    lead = ReviewerSelectSkip.self_review_lead("some-task")
    assert_includes lead, "`#{Remedy.command('task', BIN, 'show', 'some-task', '--verbose')}`"

    refusal = DeskDatabaseGuard.refusal(root: "/x/.worktrees/some-task", rails_env: "development",
                                        database_url: nil, shared_database: "studio_development")
    assert_includes refusal, Remedy.command("agent-worktree", BIN, "new", "mcritchie-studio", "some-task")

    assert_includes SeamReconcile::REPAIRS.values.join("\n"), Remedy.command("release", BIN, "prepare", "--yes")
  end

  def test_agent_worktree_prints_its_whereami_hint_through_the_helper
    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3(SessionEnv.neutralized({}), RbConfig.ruby,
                                        File.join(BIN, "agent-worktree"), "whereami", chdir: dir)
      text = "#{out}\n#{err}"

      refute status.success?, "whereami with no context must refuse:\n#{text}"
      assert_hints_resolve text, "agent-worktree", minimum: 2
    end
  end

  def test_qa_intake_prints_its_snapshot_hint_through_the_helper
    Dir.mktmpdir do |dir|
      env = SessionEnv.neutralized("AGENT_WORKTREE_REGISTRY" => File.join(dir, "missing.json"))
      out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(BIN, "qa-intake"), chdir: dir)
      text = "#{out}\n#{err}"

      refute status.success?, "a missing registry must refuse:\n#{text}"
      assert_hints_resolve text, "agent-worktree", minimum: 1
    end
  end

  # --- end to end: what bin/submit ACTUALLY PRINTS -------------------------------
  #
  # The claim refusal is the highest-traffic remedy in the house and the one that
  # fires EARLIEST — before ship has rooted — so its reader is the most likely to
  # be standing somewhere the bare form cannot resolve. It is also reachable from
  # a test without a board: a task bound to another session's dirty desk.
  #
  # The assertion is deliberately not a substring match. It splits the printed
  # command, takes the script, and asks the DISK.
  def test_submits_claim_refusal_prints_commands_that_resolve_on_disk
    Dir.mktmpdir do |root|
      work = File.join(root, "work")
      FileUtils.mkdir_p(work)
      task_bin = write_task_stub(root)
      FakeDesk.build(root, task_slug: "held-task", session: "sess-rival-9999", dirty: true)

      out, err, status = Open3.capture3(
        ship_env(root, task_bin), File.join(BIN, "submit"), "held-task", chdir: work
      )
      combined = "#{out}\n#{err}"

      refute status.success?, "a task held by another session must refuse:\n#{combined}"
      commands = printed_commands(combined)
      refute_empty commands, "the refusal must hand over a retry and a takeover command:\n#{combined}"

      commands.each do |cmd|
        script = cmd.split(" ").first
        assert_equal File.expand_path(script), script,
                     "the refusal handed over a NON-ABSOLUTE command (#{cmd.inspect}) — a satellite " \
                     "or gem desk cannot resolve it:\n#{combined}"
        assert File.executable?(script),
               "the refusal handed over #{script.inspect}, which is not an executable on this disk:\n#{combined}"
      end

      # and the two remedies it owes are both there, by NAME of the script
      assert commands.any? { |c| c.include?("/bin/submit ") }, "the retry path must be named:\n#{combined}"
      assert commands.any? { |c| c.include?("/bin/task ") }, "the takeover path must be named:\n#{combined}"
    end
  end

  private

  # Every command-looking run in the output: an absolute path under a bin/
  # directory, or a BARE `bin/<script>` — so the assertion above can catch the
  # bare form rather than silently skipping it.
  def printed_commands(text)
    text.scan(%r{(?:/[^\s"']*)?bin/(?:submit|ship|task|fast-check|dor-check)(?:[ \t]+[^\s"'\n]+)*})
        .map(&:strip).uniq
  end

  # A board CLI stub serving one task: [building]. The desk FakeDesk builds beside it
  # (another session's, with uncommitted work) is what ship's claim gate refuses on.
  def write_task_stub(root)
    path = File.join(root, "task-stub")
    payload = {
      "slug" => "held-task", "stage" => "building", "review_in_progress" => false,
      "metadata" => { "devops" => {} }
    }
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "show" ]; then printf '%s' '#{JSON.generate(payload)}'; exit 0; fi
      exit 0
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def ship_env(root, task_bin)
    SessionEnv.neutralized(
      "SHIP_TASK_BIN" => task_bin,
      "SHIP_FAST_CHECK_BIN" => task_bin,
      "SHIP_DOR_CHECK_BIN" => task_bin,
      "SHIP_ACTIVITY_BIN" => task_bin,
      "SHIP_GH_BIN" => task_bin,
      "CLAUDE_PROJECTS_DIR" => root,
      "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111",
      "TASK_CLAIM_NONCE" => "inst-default",
      # ship mints one board token up front; the chain stops at ENV (never a .env
      # or the vault) and the board is unroutable, so the mint fails fast.
      "AGENT_API_SECRET" => "test-secret"
    )
  end

  # Every `<path>bin/<script>` in +text+ is absolute and executable, and there are at
  # least +minimum+ of them. A bare `bin/<script>` is collected too, so it fails here
  # rather than being skipped.
  def assert_hints_resolve(text, script, minimum:)
    hits = text.scan(%r{(?:/[^\s"'`]*)?bin/#{Regexp.escape(script)}(?![\w-])})
    assert_operator hits.size, :>=, minimum, "expected #{minimum}+ #{script} hint(s):\n#{text}"
    hits.each { |hit| assert_runnable hit, text }
  end

  def assert_runnable(command, context)
    script = command.split(" ").first.to_s
    assert_equal File.expand_path(script), script, "a NON-ABSOLUTE hint (#{command.inspect}):\n#{context}"
    assert File.executable?(script), "#{script.inspect} is not an executable on this disk:\n#{context}"
  end
end

# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# [integration] A desk-side command, and a real hub tree moving under it.
#
# THE DEFECT, measured four times on 2026-09-10 across three sessions. Every
# desk-side command loads its libraries with `require_relative` against the
# checkout the SCRIPT lives in. Invoked by its hub-primary absolute path, that
# is a checkout other processes move, and a tracked file is absent for ~0.4-0.7s
# of every checkout (measured 2026-09-13). A command that starts inside that
# window dies with `cannot load such file`.
#
# THE TWO HALVES THIS ASSERTS, which are two different defects:
#
#   HALF 1 — a desk exists and carries its own copy. The command hands off to
#     it BEFORE loading anything, so a hub tree that has lost its libraries
#     cannot hurt it. Proven here with the hub deliberately broken; the control
#     leg (MCR_SKIP_DESK_HANDOFF=1) shows the same command dying without it.
#
#   HALF 2 — no desk copy exists (bin/agent-worktree always, and EVERY satellite
#     desk, because only mcritchie-studio ships these scripts). Nothing can be
#     handed off to, so the error must at least say whose bug it is. Asserted
#     here on the real error text, together with the control that it stays
#     SILENT for a genuinely missing file.
#
# NOTHING HERE TOUCHES the real hub primary or a live desk: the "hub" and "desk"
# below are throwaway `git init` trees in a tmpdir, seeded with the real scripts.
class DeskCommandSurvivesHubMoveTest < ActiveSupport::TestCase
  # The real closure of bin/ship-wait — verified 2026-09-13: neither
  # bin/lib/repo_root.rb nor bin/lib/ship_wait.rb requires anything further.
  CLOSURE = %w[
    bin/ship-wait
    bin/lib/hub_move_diagnosis.rb
    bin/lib/repo_root.rb
    bin/lib/ship_wait.rb
  ].freeze

  # The library the "mid-checkout" commit is missing. Chosen because it is a
  # genuine dependency of bin/ship-wait, so its absence produces the real
  # LoadError rather than a staged one.
  VANISHED = "bin/lib/ship_wait.rb"

  def setup
    @sandbox = Dir.mktmpdir("desk-command-hub-move")
    @hub = File.join(@sandbox, "hub")
    @desk = File.join(@sandbox, "desk")
    seed_hub!
    seed_desk!
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # ── HALF 1 ──────────────────────────────────────────────────────────────────

  # The hub has lost a library. A builder standing on a desk, invoking the hub's
  # absolute path — the shape every dispatch brief uses — still succeeds,
  # because the handoff happens before the first require_relative.
  def test_a_desk_copy_survives_a_hub_that_has_lost_its_libraries
    git!(@hub, "checkout", "--quiet", "mid-checkout")
    refute_path_exists File.join(@hub, VANISHED), "the hub tree did not actually move"
    assert_path_exists File.join(@desk, VANISHED), "the desk should be unaffected by the hub moving"

    out, err, status = run_hub_script(cwd: @desk)

    assert_predicate status, :success?,
                     "the desk-side command died even though the desk carries an intact copy (stderr=#{err})"
    assert_match(/handing off to this checkout's own copy/, err,
                 "the handoff must ANNOUNCE itself — it changes which code runs")
    assert_match(/Usage: bin\/ship-wait/, out + err, "the handed-off copy did not actually run")
    refute_match(/cannot load such file/, err, "a library still failed to load after the handoff")
  end

  # THE CONTROL for the test above, and the proof it bites: the identical
  # command with the handoff disarmed is the CURRENT behaviour, and it dies.
  def test_without_the_handoff_the_same_command_dies_on_the_moved_hub
    git!(@hub, "checkout", "--quiet", "mid-checkout")

    _out, err, status = run_hub_script(cwd: @desk, env: { "MCR_SKIP_DESK_HANDOFF" => "1" })

    refute_predicate status, :success?,
                     "with the handoff disarmed this must reproduce the defect; if it passes, the test " \
                     "above proves nothing"
    assert_match(/cannot load such file/, err)
  end

  # The handoff must hold while the tree is genuinely churning, not just while it
  # sits on one broken commit.
  def test_the_desk_copy_survives_a_hub_that_is_actively_moving
    stop = false
    flips = 0
    mover = Thread.new do
      until stop
        git!(@hub, "checkout", "--quiet", flips.even? ? "mid-checkout" : "main")
        flips += 1
      end
    rescue StandardError
      nil
    end

    failures = []
    10.times do
      _out, err, status = run_hub_script(cwd: @desk)
      failures << err unless status.success?
    end
    stop = true
    mover.join(20)

    assert_operator flips, :>, 1, "the mover never flipped the hub; the concurrency was not exercised"
    assert_empty failures, "the desk copy failed #{failures.size}/10 times while the hub moved under it"
  end

  # ── HALF 2 ──────────────────────────────────────────────────────────────────

  # No desk copy to hand off to. The command still dies — there is no retry, by
  # design — but the error now says whose bug it is.
  def test_a_hub_only_command_reports_the_move_instead_of_a_bare_load_error
    hub_mid_checkout!

    _out, err, status = run_hub_script(cwd: @hub)

    refute_predicate status, :success?, "the diagnosis must not rescue the command; there is no retry here"
    assert_match(/cannot load such file/, err,
                 "the ORIGINAL LoadError must still print — the diagnosis is context, not a replacement")

    assert_match(/HUB CHECKOUT MOVED UNDER THIS COMMAND/, err, "the error does not name the mechanism")
    assert_match(/NOT your bug/, err, "the error does not tell the builder to stop debugging their diff")
    assert_match(/Re-run the command/, err, "the error does not name the remedy")
    assert_match(/#{Regexp.escape(VANISHED)}/, err, "the error does not name the file that vanished")
    assert_match(/Last HEAD move:.*checkout: moving/, err,
                 "the error does not show the reflog entry that proves the tree moved — that evidence is " \
                 "what makes it SELF-diagnosing rather than merely sympathetic")
  end

  # THE CRY-WOLF CONTROL. A require that was never satisfiable is a typo or a
  # bad merge, not an infrastructure hiccup, and dressing it up as one would
  # send the reader to re-run a command that can never succeed.
  def test_a_genuinely_missing_file_gets_no_diagnosis
    _out, err, status = Open3.capture3(sandbox_env, File.join(@hub, "bin", "probe-missing"))

    refute_predicate status, :success?
    assert_match(/cannot load such file/, err, "the probe did not fail the way this test needs")
    refute_match(/HUB CHECKOUT MOVED/, err,
                 "a file that never existed in HEAD was reported as a moved tree — the diagnosis cries wolf, " \
                 "and a builder would re-run a command that cannot ever work")
  end

  private

  # Put the hub into the state a checkout passes THROUGH, precisely.
  #
  # `git checkout` unlinks a path and creates it afresh, so mid-flight the file
  # is ABSENT FROM THE WORKING TREE WHILE STILL PRESENT IN HEAD. That pairing is
  # the whole discriminator, so the test has to reproduce it rather than
  # approximate it. Checking out a commit that DELETED the file is a different
  # thing and must NOT be diagnosed as a move — the file genuinely is not in
  # that commit — which is why the Half 1 tests can use the mid-checkout branch
  # but this one cannot.
  def hub_mid_checkout!
    git!(@hub, "checkout", "--quiet", "main")
    FileUtils.rm_f(File.join(@hub, VANISHED))

    _out, status = Open3.capture2e("git", "-C", @hub, "cat-file", "-e", "HEAD:#{VANISHED}")
    assert_predicate status, :success?,
                     "the state under test requires #{VANISHED} to be present in HEAD; if it is not, " \
                     "this test is asserting against a genuinely missing file and proves nothing"
    refute_path_exists File.join(@hub, VANISHED)
  end

  def seed_hub!
    CLOSURE.each { |rel| install(Rails.root.join(rel).to_s, File.join(@hub, rel)) }

    # A hub-only script whose require can NEVER resolve: the control for the
    # discriminator. It arms the same guard the real scripts arm.
    probe = File.join(@hub, "bin", "probe-missing")
    File.write(probe, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require_relative "lib/hub_move_diagnosis"
      HubMoveDiagnosis.install!(root: File.expand_path("..", __dir__), command: "probe-missing")
      require_relative "lib/a_file_that_never_existed"
    RUBY
    File.chmod(0o755, probe)

    git!(@hub, "init", "--quiet", "--initial-branch=main")
    git!(@hub, "add", "--all")
    commit!(@hub, "v1 the closure as it ships")

    # The "mid-checkout" commit: the tree as it looks while git is rewriting it.
    # A commit that omits the file holds that state open long enough to assert
    # on, instead of racing a sub-second window for it.
    git!(@hub, "checkout", "--quiet", "-b", "mid-checkout")
    git!(@hub, "rm", "--quiet", VANISHED)
    commit!(@hub, "v2 as the tree looks mid-checkout")
    git!(@hub, "checkout", "--quiet", "main")
  end

  # A desk: a separate checkout carrying its own copy of everything, pinned to
  # its own branch. Nobody moves it, which is the entire point.
  def seed_desk!
    CLOSURE.each { |rel| install(File.join(@hub, rel), File.join(@desk, rel)) }
    git!(@desk, "init", "--quiet", "--initial-branch=feat-desk")
    git!(@desk, "add", "--all")
    commit!(@desk, "the desk's own pinned copy")
  end

  def install(from, to)
    FileUtils.mkdir_p(File.dirname(to))
    FileUtils.cp(from, to)
    File.chmod(File.stat(from).mode & 0o7777, to)
  end

  def run_hub_script(cwd:, env: {})
    Open3.capture3(sandbox_env.merge(env), File.join(@hub, "bin", "ship-wait"), "--help", chdir: cwd)
  end

  # CLAUDE_PROJECTS_DIR is pinned so nothing here can reach the operator's real
  # <projects>/.agents under the suite's TASK_USAGE_SANDBOX.
  def sandbox_env
    { "CLAUDE_PROJECTS_DIR" => @sandbox, "PROJECTS_DIR" => @sandbox }
  end

  def commit!(dir, message)
    git!(dir, "-c", "user.name=Test", "-c", "user.email=test@example.com",
         "-c", "commit.gpgsign=false", "commit", "--quiet", "--message", message)
  end

  def git!(dir, *args)
    FileUtils.mkdir_p(dir)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end

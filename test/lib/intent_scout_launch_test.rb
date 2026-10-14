# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/intent_scout"

# [unit] IntentScout.auto_launch: `bin/task begin` launches Avi's intent scout
# itself, detached, ONCE (scout-launches-itself). No real process is ever started:
# every case hands in a recording spawner, and the env is a plain Hash, never the
# test process's own. The wiring through bin/task is pinned in
# test/lib/task_begin_test.rb.
class IntentScoutLaunchTest < Minitest::Test
  SLUG = "demo-task"
  DESK = "/projects/hub/.worktrees/demo-task"

  def setup
    @root = Dir.mktmpdir("intent-scout-launch")
    @home = File.join(@root, "state")
    @claude = File.join(@root, "bin", "claude")
    FileUtils.mkdir_p(File.dirname(@claude))
    File.write(@claude, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, @claude)
    @spawns = []
    @next_pid = 4242
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  # An operator's laptop: claude on PATH, no CI, no sandbox, a state dir.
  def laptop(extra = {})
    { "PATH" => File.dirname(@claude), "HOME" => @root, "INTENT_SCOUT_HOME" => @home }.merge(extra)
  end

  def spawner
    lambda do |env, *argv, **opts|
      @spawns << { env: env, argv: argv, opts: opts }
      @next_pid
    end
  end

  def launch(env, resume: false, **opts)
    IntentScout.auto_launch(SLUG, DESK, resume: resume, env: env, hub_dir: @root, spawner: spawner,
                                        detacher: nil, **opts)
  end

  def test_spawns_once_records_the_pid_and_a_second_begin_reports_the_first
    first = launch(laptop)

    assert_equal :launched, first[:kind]
    assert_equal 1, @spawns.size
    assert_equal "4242", File.read(File.join(@home, "#{SLUG}.pid"))
    assert_equal File.join(@home, "#{SLUG}.log"), first[:log]
    assert_equal 1, first[:lines].size, "the launched line, and not the paste-ready block too"
    assert_match(/\Ascout: Avi launched in the background \(pid 4242, log .*demo-task\.log\) - do not launch another/,
                 first[:lines].first)
    refute_includes first[:lines].join, "Agent(", "never both"

    second = launch(laptop)
    assert_equal :prior, second[:kind]
    assert_equal 1, @spawns.size, "never twice"
    assert_includes second[:lines].first, "already launched for this task (pid 4242"
  end

  def test_the_headless_command_is_avi_dont_ask_and_read_only
    launch(laptop)
    argv = @spawns.first[:argv]

    assert_equal [@claude, "-p", "--agent", "avi", "--permission-mode", "dontAsk"], argv.first(6)
    tools = argv[argv.index("--allowedTools") + 1].split(",")
    assert_includes tools, "Read"
    assert_includes tools, "Bash(bin/task note *)", "the scout must be able to post its brief"
    refute(tools.any? { |t| t.match?(/\A(Edit|Write|NotebookEdit)\b/) }, "the scout never edits: #{tools}")
    refute_includes tools, "Bash", "no unrestricted shell"
    assert_includes argv.last, "intent-scout SOP"
    assert_includes argv.last, "headless"
    assert_equal @root, @spawns.first[:opts][:chdir]
    assert @spawns.first[:opts][:pgroup], "detached from begin's process group"
  end

  def test_the_child_env_is_an_allow_list_with_the_rest_unset
    env = laptop("CLAUDE_CODE_SESSION_ID" => "builder-session", "CODEX_THREAD_ID" => "t",
                 "TASK_AS_ADMIN" => "1", "AGENT_ADMIN_SESSION_TOKEN" => "secret",
                 "AGENT_API_TOKEN" => "bearer", "LC_ALL" => "C", "TASK_API_BASE" => "http://127.0.0.1:9")
    launch(env)
    child = @spawns.first[:env]

    assert @spawns.first[:opts][:unsetenv_others], "everything not passed is unset"
    %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID TASK_AS_ADMIN AGENT_ADMIN_SESSION_TOKEN AGENT_API_TOKEN].each do |key|
      refute child.key?(key), "#{key} must not reach the scout"
    end
    assert_equal "C", child["LC_ALL"]
    assert_equal "http://127.0.0.1:9", child["TASK_API_BASE"]
    assert_equal File.dirname(@claude), child["PATH"]
  end

  def test_the_opt_out_prints_the_block_and_spawns_nothing
    result = launch(laptop("INTENT_SCOUT_AUTO" => "0"))

    assert_equal :manual, result[:kind]
    assert_empty @spawns
    assert_includes result[:lines].join("\n"), 'Agent(subagent_type: "avi"'
    assert_includes result[:lines][1], "Auto-launch did not run (INTENT_SCOUT_AUTO=0)"
    refute File.exist?(File.join(@home, "#{SLUG}.pid"))
  end

  def test_ci_and_the_test_suite_never_launch_through_path
    [{ "CI" => "true" }, { "GITHUB_ACTIONS" => "true" }, { "TASK_USAGE_SANDBOX" => "1" },
     { "RAILS_ENV" => "test" }].each do |extra|
      result = launch(laptop(extra))
      assert_equal :manual, result[:kind], extra.inspect
      assert_includes result[:reason], "CI or the test suite"
    end
    assert_empty @spawns
  end

  def test_an_explicit_stub_binary_is_the_only_way_to_launch_in_the_suite
    result = launch(laptop("TASK_USAGE_SANDBOX" => "1", "PATH" => "/nowhere", "TASK_BEGIN_SCOUT_BIN" => @claude))

    assert_equal :launched, result[:kind]
    assert_equal @claude, @spawns.first[:argv].first
  end

  def test_no_cli_falls_back_to_the_block
    result = launch(laptop("PATH" => File.join(@root, "empty")))

    assert_equal :manual, result[:kind]
    assert_includes result[:reason], "no claude CLI"
    assert_empty @spawns
  end

  def test_a_failed_spawn_falls_back_and_frees_the_claim
    boom = ->(*_args, **_opts) { raise Errno::ENOENT, "claude" }
    result = IntentScout.auto_launch(SLUG, DESK, resume: false, env: laptop, hub_dir: @root, spawner: boom, detacher: nil)

    assert_equal :manual, result[:kind]
    assert_includes result[:reason], "the launch failed"
    refute File.exist?(File.join(@home, "#{SLUG}.pid")), "a failed spawn must not block the next begin"
  end

  def test_a_resume_never_spawns
    assert_equal :manual, launch(laptop, resume: true)[:kind]
    assert_equal :brief, launch(laptop, resume: true, brief_lookup: -> { { "slug" => "a" } })[:kind]
    assert_equal :manual, launch(laptop, resume: true, brief_lookup: -> { raise "board down" })[:kind]
    assert_empty @spawns
  end

  def test_the_cap_counts_live_scouts
    FileUtils.mkdir_p(@home)
    IntentScout::CAP.times { |i| File.write(File.join(@home, "other-#{i}.pid"), Process.pid.to_s) }
    result = launch(laptop)

    assert_equal :manual, result[:kind]
    assert_includes result[:reason], "the cap is #{IntentScout::CAP}"
    assert_empty @spawns

    FileUtils.rm(Dir.glob(File.join(@home, "other-*.pid")))
    File.write(File.join(@home, "dead.pid"), "999999999")
    assert_equal :launched, launch(laptop)[:kind], "a finished scout does not count"
  end

  def test_the_summary_line_names_every_outcome
    assert_includes IntentScout.summary_line(kind: :launched, pid: 7), "launched in the background (pid 7)"
    assert_includes IntentScout.summary_line(kind: :prior), "already launched"
    assert_includes IntentScout.summary_line(kind: :brief), "brief is already"
    assert_includes IntentScout.summary_line(kind: :manual, reason: "x"), "NOT launched (x)"
  end

  def test_the_owed_note_carries_the_pid
    note = IntentScout.owed_note(SLUG, DESK, { kind: :launched, pid: 99, log: "/l.log" })

    assert note.start_with?(IntentScout::OWED_MARKER)
    assert_includes note, "pid 99"
    refute IntentScout.brief?("activity_type" => "comment", "description" => note)
  end
end

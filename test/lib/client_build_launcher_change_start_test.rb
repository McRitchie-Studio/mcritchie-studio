# frozen_string_literal: true

# [unit] ClientBuildLauncher::ChangeStart, the launcher's start of a chat-sourced
# change card: the exact bin/task begin argv, the desk read from begin's worktree
# line, and a refusal's reason (its last lines, never a link or token line).
#   ruby -Itest test/lib/client_build_launcher_change_start_test.rb
require "minitest/autorun"
require_relative "../../bin/lib/client_build_launcher"

class ClientBuildLauncherChangeStartTest < Minitest::Test
  Status = Struct.new(:code) do
    def success? = code.zero?
    def exitstatus = code
  end

  def start(output, status, calls = [])
    runner = lambda do |argv, chdir:, timeout:|
      calls << [ argv, chdir, timeout ]
      [ output, status ]
    end
    ClientBuildLauncher::ChangeStart.new(task_bin: "/fixed/task", chdir: "/hub", timeout: 60, runner: runner)
  end

  def test_runs_begin_with_the_slug_and_reads_the_desk
    calls = []
    result = start("app · s · url\nworktree: /p/turf-monster/.worktrees/dark-toggle\nmagic link: http://x/?t=secret\n",
                   Status.new(0), calls).call("dark-toggle")

    assert result.ok
    assert_equal "/p/turf-monster/.worktrees/dark-toggle", result.desk
    assert_equal [ [ [ "/fixed/task", "begin", "dark-toggle", "--agent", "pokemon" ], "/hub", 60 ] ], calls
  end

  def test_an_unusable_slug_runs_nothing
    calls = []
    [ "Dark Toggle", "x; rm -rf ~", "", "-flag" ].each do |slug|
      result = start("", Status.new(0), calls).call(slug)
      refute result.ok
      assert_equal "the board named an unusable slug", result.reason
    end
    assert_empty calls
  end

  def test_a_refusal_carries_its_last_lines_without_a_link_or_token
    out = "begin 2/5 worktree\nmagic link: http://localhost:3100/x?token=abc\nusing token sk-123\nno free port in 3100-3199\n"
    result = start(out, Status.new(1)).call("no-slot")

    refute result.ok
    assert_equal "bin/task begin exited 1: begin 2/5 worktree | no free port in 3100-3199", result.reason
    refute_match(/token|abc|sk-123/, result.reason)
  end

  def test_a_success_without_a_worktree_line_is_a_refusal
    refute start("all good\n", Status.new(0)).call("odd").ok
  end

  def test_a_timeout_is_a_refusal
    result = start("half", nil).call("slow")
    refute result.ok
    assert_equal "bin/task begin ran past 1 minutes", result.reason
  end
end

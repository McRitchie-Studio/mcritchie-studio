# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/intent_scout"

# [integration] LIVE SMOKE of the headless intent scout's permissions, against the
# REAL `claude` CLI (scout-launches-itself, Carl's block of 2026-10-14).
#
# WHY A LIVE TEST. The scout runs unattended in the hub primary and reads desk
# content an agent wrote, so what it may run is a security boundary. The first
# draft's argv looked read-only and was not: the CLI ADDED the operator's
# ~/.claude/settings.json allow rules under dontAsk (Carl staged a file with
# `git add`), and `rg --pre` and `git show --output` were escapes inside the
# allow-list itself. An argv assertion cannot see what the CLI adds; only the CLI
# can answer. So this runs IntentScout.launch_command's exact argv (the prompt
# swapped for a probe, the output switched to JSON so the denials are readable)
# and asserts on the filesystem and on the CLI's own permission_denials.
#
# GATED OFF by default and always in CI: it spends a model call and needs the
# operator's login. Run it by hand after any change to the launch argv:
#
#   INTENT_SCOUT_LIVE_SMOKE=1 ruby -Itest test/lib/intent_scout_cli_smoke_test.rb
class IntentScoutCliSmokeTest < Minitest::Test
  def setup
    skip "live smoke: set INTENT_SCOUT_LIVE_SMOKE=1 to run" unless ENV["INTENT_SCOUT_LIVE_SMOKE"] == "1"
    skip "live smoke never runs in CI" if ENV["CI"].to_s != "" || ENV["GITHUB_ACTIONS"].to_s != ""
    @env = ENV.to_h.reject { |k, _| k == IntentScout::BIN_ENV }
    @claude = IntentScout.claude_bin(@env) || skip("no claude CLI on PATH")
    @agent = IntentScout.agent_json(@env) || skip("no avi agent definition")
    @root = File.realpath(Dir.mktmpdir("scout-smoke"))
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def script(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def test_the_exact_launch_argv_denies_writes_and_escapes_and_allows_the_brief
    repo = File.join(@root, "repo")
    FileUtils.mkdir_p(repo)
    system("git", "-C", repo, "init", "-q") || flunk("git init")
    File.write(File.join(repo, "a.txt"), "a\n")
    system("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "i")
    bin = File.join(@root, "bin")
    FileUtils.mkdir_p(bin)
    note_marker = File.join(@root, "note-ran")
    pre_marker = File.join(@root, "pre-ran")
    show_out = File.join(@root, "show-output.txt")
    script(File.join(bin, "task"), "echo \"$@\" > #{note_marker}")
    pre = script(File.join(@root, "pre.sh"), "touch #{pre_marker}; cat \"$1\"")

    probes = [
      "cd #{repo} && git add a.txt",
      "cd #{repo} && git show --output=#{show_out} HEAD",
      "rg --pre #{pre} a #{repo}",
      "#{bin}/task note smoke-task --comment \"INTENT SCOUT BRIEF: smoke\" --agent avi"
    ]
    prompt = "Permission probe. Run each of these four shell commands with the Bash tool, one call each, " \
             "exactly as written, even if you expect a denial; do nothing else:\n" +
             probes.each_with_index.map { |c, i| "#{i + 1}. #{c}" }.join("\n")
    argv = IntentScout.launch_command("smoke-task", repo, bin: @claude, projects_dir: @root, agent_json: @agent,
                                                          bin_dirs: [bin], prompt: prompt)
    out, err, status = Open3.capture3(IntentScout.child_env(@env), *argv, "--output-format", "json",
                                      unsetenv_others: true, chdir: repo, stdin_data: "")
    puts "\n[live smoke] exit #{status.exitstatus}\n#{out}\n#{err}" if ENV["INTENT_SCOUT_LIVE_SMOKE_VERBOSE"] == "1"
    result = JSON.parse(out)
    denied = Array(result["permission_denials"]).map { |d| d.dig("tool_input", "command").to_s }

    assert File.exist?(note_marker), "bin/task note must be ALLOWED (the scout posts its brief):\n#{out}"
    assert_empty `git -C #{repo} diff --cached --name-only`.strip, "git add must be DENIED"
    refute File.exist?(show_out), "git show --output must be DENIED"
    refute File.exist?(pre_marker), "rg --pre must be DENIED"
    %w[git\ add git\ show rg\ --pre].each do |needle|
      assert(denied.any? { |c| c.include?(needle) },
             "the CLI must record #{needle.inspect} as a permission denial (proves it was attempted): #{denied}")
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../bin/lib/intent_scout"

# [unit] The headless intent scout runs with `--setting-sources project`, so the
# hub's own .claude/settings.json is loaded and, under dontAsk, its allow rules are
# ADDED to the scout's. These pin (1) that the TRACKED hub file grants the scout
# nothing that writes or executes, (2) the allow-list rule that holds it, checked
# again at every launch, and (3) that the scout may note only the task it scouts.
# Carl's two notes on scout-launches-itself, 2026-10-15.
class IntentScoutProjectSettingsTest < Minitest::Test
  HUB = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir("scout-settings")
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def settings(hash_or_text)
    FileUtils.mkdir_p(File.join(@dir, ".claude"))
    body = hash_or_text.is_a?(String) ? hash_or_text : JSON.generate(hash_or_text)
    File.write(File.join(@dir, ".claude", "settings.json"), body)
    IntentScout.project_settings_violations(@dir)
  end

  def test_the_tracked_hub_project_settings_grant_the_scout_nothing
    assert_equal [], IntentScout.project_settings_violations(HUB),
                 "the hub's .claude/settings.json would widen the read-only scout's allow-list"
  end

  def test_no_file_and_read_only_rules_pass
    assert_equal [], IntentScout.project_settings_violations(@dir)
    assert_equal [], settings("$schema" => "x", "permissions" => { "allow" => ["Read", "Grep(*)", "Glob"],
                                                                   "deny" => ["Bash(*)"], "defaultMode" => "plan" })
  end

  def test_a_write_or_execute_allow_rule_is_a_violation
    %w[Bash Bash(bin/rails\ test\ *) Edit Write NotebookEdit WebFetch mcp__x__y].each do |rule|
      violations = settings("permissions" => { "allow" => [rule] })
      assert_equal 1, violations.size, rule
      assert_includes violations.first, "allows #{rule}"
    end
  end

  def test_any_key_off_the_allow_list_is_a_violation
    assert_includes settings("hooks" => { "PreToolUse" => [] }).join, "sets hooks"
    assert_includes settings("env" => { "PATH" => "./bin" }).join, "sets env"
    assert_includes settings("apiKeyHelper" => "./x.sh").join, "sets apiKeyHelper"
    assert_includes settings("permissions" => { "defaultMode" => "bypassPermissions" }).join, "defaultMode bypassPermissions"
    assert_includes settings("permissions" => { "acceptEverything" => true }).join, "permissions.acceptEverything"
  end

  def test_a_malformed_file_fails_closed
    assert_includes settings("{ not json").join, "could not be read"
    assert_includes settings("[]").join, "not a JSON object"
  end

  def test_a_widening_settings_file_stops_the_auto_launch
    claude = File.join(@dir, "bin", "claude")
    FileUtils.mkdir_p(File.dirname(claude))
    File.write(claude, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, claude)
    FileUtils.mkdir_p(File.join(@dir, ".claude", "agents"))
    File.write(File.join(@dir, ".claude", "agents", "avi.md"), "---\nname: avi\ndescription: Avi.\n---\n\nYou are Avi.\n")
    settings("permissions" => { "allow" => ["Bash(git add *)"] })
    spawns = []
    env = { "PATH" => File.dirname(claude), "HOME" => @dir, "INTENT_SCOUT_HOME" => File.join(@dir, "state") }

    outcome = IntentScout.auto_launch("demo-task", "/desk", resume: false, env: env, hub_dir: @dir,
                                                            spawner: ->(*args, **) { spawns << args; 1 },
                                                            detacher: nil, exited: ->(_pid, _grace) { nil })

    assert_equal :manual, outcome[:kind]
    assert_includes outcome[:reason], "allows Bash(git add *)"
    assert_empty spawns, "never spawned"
    refute File.exist?(File.join(@dir, "state", "demo-task.pid")), "the claim is released for the next begin"
  end

  def test_the_note_rule_names_only_the_scouted_task
    tools = IntentScout.allowed_tools("demo-task", ["/hub/bin"])

    assert_includes tools, "Bash(bin/task note demo-task *)"
    assert_includes tools, "Bash(/hub/bin/task note demo-task *)"
    assert_equal 2, tools.count { |t| t.include?("task note") }
    assert_raises(ArgumentError) { IntentScout.note_rule("demo-task *") }
    assert_raises(ArgumentError) { IntentScout.note_rule("") }
  end
end

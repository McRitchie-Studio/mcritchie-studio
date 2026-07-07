# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class PrReviewCommandTest < Minitest::Test
  BIN = File.expand_path("../../bin/pr-review", __dir__)

  def setup
    @dir = Dir.mktmpdir("pr-review-test")
    @snapshots = File.join(@dir, "snapshots")
    @output = File.join(@dir, "output")
    FileUtils.mkdir_p(@snapshots)
    FileUtils.mkdir_p(@output)
    @counter = File.join(@dir, "counter")
    @devops_log = File.join(@dir, "devops-cycle.log")
    @reviewer_log = File.join(@dir, "reviewer-select.log")
    @codex_log = File.join(@dir, "codex.log")
    @task_log = File.join(@dir, "task.log")
    @sequence_log = File.join(@dir, "sequence.log")
    @narration_log = File.join(@dir, "narration.log")
    write_fakes
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_fakes
    write_exec("devops-cycle", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("DEVOPS_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      counter = ENV.fetch("SNAPSHOT_COUNTER")
      index = File.exist?(counter) ? File.read(counter).to_i : 0
      File.write(counter, index + 1)
      files = Dir[File.join(ENV.fetch("SNAPSHOT_DIR"), "snapshot-*.json")].sort
      abort "no snapshots" if files.empty?
      puts File.read(files[[index, files.length - 1].min])
    RUBY

    write_exec("reviewer-select", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("REVIEWER_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      puts JSON.generate("reviewers" => [
        { "slug" => "carl", "weight" => "primary" },
        { "slug" => "shannon", "weight" => "light" }
      ])
    RUBY

    write_exec("codex", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("CODEX_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      prompt = STDIN.read
      slug = prompt[/reviewer for ([A-Za-z0-9._-]+)/, 1] || "unknown"
      reviewer = prompt[/as ([A-Za-z0-9._-]+), a pr-review/, 1] || "unknown"
      narration = prompt.scan(%r{^bin/agent-activity .*$})
      File.open(ENV.fetch("NARRATION_LOG"), "a") { |f| f.puts JSON.generate([reviewer, slug, narration]) }
      File.open(ENV.fetch("SEQUENCE_LOG"), "a") { |f| f.puts JSON.generate(["codex", slug, ARGV]) }
      sleep ENV.fetch("CODEX_SLEEP", "0").to_f
      if (idx = ARGV.index("-o"))
        File.write(ARGV.fetch(idx + 1), "fake review complete\\n")
      end
      exit ENV["CODEX_FAIL"].to_s == "1" ? 1 : 0
    RUBY

    write_exec("task", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("TASK_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      File.open(ENV.fetch("SEQUENCE_LOG"), "a") { |f| f.puts JSON.generate(["task", *ARGV]) }
      puts "task fake: \#{ARGV.join(" ")}"
    RUBY
  end

  def write_exec(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def write_snapshots(*snapshots)
    snapshots.each_with_index do |snapshot, index|
      File.write(File.join(@snapshots, "snapshot-%02d.json" % index), JSON.pretty_generate(snapshot))
    end
  end

  def snapshot(tasks)
    {
      "generated_at" => "2026-06-29T12:00:00Z",
      "tasks" => tasks,
      "decisions" => tasks.select { |task| task["stage"] == "submitted" }.map { |task| decision_for(task) }
    }
  end

  def decision_for(task)
    outcomes = Array(task["scout_reports"]).map { |report| report["outcome"] }
    recommendation =
      if outcomes.include?("request-changes")
        "request-changes"
      elsif outcomes.include?("wait-for-ci")
        "wait-for-ci"
      elsif outcomes.count("merge-ready") >= 2
        "merge-ready"
      else
        "conductor-review"
      end

    {
      "slug" => task.fetch("slug"),
      "title" => task.fetch("title"),
      "recommendation" => recommendation,
      "reasons" => ["fixture"],
      "scout_report_counts" => outcomes.each_with_object(Hash.new(0)) { |outcome, counts| counts[outcome] += 1 }
    }
  end

  def task(slug, created_at:, submitted_at: nil, reports: [], stage: "submitted")
    submitted_at ||= created_at

    {
      "slug" => slug,
      "title" => slug.tr("-", " ").capitalize,
      "stage" => stage,
      "priority" => 1,
      "created_at" => created_at,
      "submitted_at" => submitted_at,
      "task_url" => "https://www.mcritchie.studio/tasks/#{slug}",
      "repositories" => ["mcritchie-studio"],
      "devops" => {
        "kind" => "feature",
        "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["devops"],
        "branch" => "feat/#{slug}",
        "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/#{slug.hash.abs % 10_000}",
        "acceptance" => ["Review works for #{slug}"],
        "test_plan" => ["bin/rails test"],
        "checks_run" => ["bin/rails test"]
      },
      "scout_reports" => reports
    }
  end

  def report(agent, outcome, summary = "#{outcome} summary")
    {
      "agent_slug" => agent,
      "outcome" => outcome,
      "summary" => summary,
      "findings" => [],
      "questions" => [],
      "checks" => [],
      "created_at" => "2026-06-29T12:10:00Z"
    }
  end

  def run_heartbeat(*args, env: {})
    full_env = {
      "DEVOPS_CYCLE_BIN" => File.join(@dir, "devops-cycle"),
      "REVIEWER_SELECT_BIN" => File.join(@dir, "reviewer-select"),
      "TASK_BIN" => File.join(@dir, "task"),
      "CODEX_BIN" => File.join(@dir, "codex"),
      "SNAPSHOT_DIR" => @snapshots,
      "SNAPSHOT_COUNTER" => @counter,
      "DEVOPS_LOG" => @devops_log,
      "REVIEWER_LOG" => @reviewer_log,
      "CODEX_LOG" => @codex_log,
      "TASK_LOG" => @task_log,
      "SEQUENCE_LOG" => @sequence_log,
      "NARRATION_LOG" => @narration_log
    }.merge(env)

    Open3.capture3(
      full_env,
      RbConfig.ruby,
      BIN,
      "--idle-sleep", "0",
      "--max-idle-cycles", "0",
      "--output-dir", @output,
      *args
    )
  end

  def json_lines(path)
    return [] unless File.exist?(path)

    File.readlines(path).map { |line| JSON.parse(line) }
  end

  # Prompt files are written by launch_reviewer as <slug>--<role>--<reviewer>.prompt
  # in both dry-run and run mode; keyed by reviewer slug here.
  def prompt_files_by_reviewer
    Dir[File.join(@output, "**", "*.prompt")].each_with_object({}) do |path, map|
      reviewer = File.basename(path, ".prompt").split("--").last
      map[reviewer] = File.read(path)
    end
  end

  def assert_narration_instructions(prompt, reviewer_slug, task_slug)
    assert_includes prompt,
                    "bin/agent-activity start --category Verify --agent #{reviewer_slug} " \
                    "--supervisor avi --task #{task_slug} --reason \"review: #{task_slug}\"",
                    "#{reviewer_slug} prompt must open a soul-attributed Verify activity"
    assert_includes prompt, "bin/agent-activity end --outcome",
                    "#{reviewer_slug} prompt must close the activity with the verdict"
  end

  def test_prefers_latest_submitted_at_over_task_creation_time
    older_resubmitted = task(
      "older-resubmitted",
      created_at: "2026-06-29T09:00:00Z",
      submitted_at: "2026-06-29T12:30:00Z"
    )
    newer_created = task(
      "newer-created",
      created_at: "2026-06-29T12:00:00Z",
      submitted_at: "2026-06-29T12:00:00Z"
    )
    older_reviewed = task(
      "older-resubmitted",
      created_at: "2026-06-29T09:00:00Z",
      submitted_at: "2026-06-29T12:30:00Z",
      reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")]
    )

    write_snapshots(
      snapshot([older_resubmitted, newer_created]),
      snapshot([older_reviewed, newer_created])
    )

    out, err, status = run_heartbeat("--run", "--limit", "1")

    assert status.success?, err
    assert_includes out, "Review 1/1: older-resubmitted"

    reviewer_calls = json_lines(@reviewer_log)
    assert_equal ["older-resubmitted"], reviewer_calls.map(&:first)

    moves = json_lines(@task_log).select { |args| args.first == "move" }
    assert_equal [["move", "older-resubmitted", "reviewed", "--actor", "avi"]], moves
  end

  def test_runs_newest_submitted_pr_first_then_re_queries_before_the_next_review
    old = task("old-pr", created_at: "2026-06-29T10:00:00Z")
    first = task("first-new", created_at: "2026-06-29T11:00:00Z")
    second = task("second-new", created_at: "2026-06-29T11:30:00Z")
    first_reviewed = task("first-new", created_at: "2026-06-29T11:00:00Z",
                                       reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    second_reviewed = task("second-new", created_at: "2026-06-29T11:30:00Z",
                                         reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])

    write_snapshots(
      snapshot([old, first]),
      snapshot([old, first_reviewed]),
      snapshot([old, second]),
      snapshot([old, second_reviewed])
    )

    out, err, status = run_heartbeat("--run", "--limit", "2")

    assert status.success?, err
    assert_includes out, "Review 1/2: first-new"
    assert_includes out, "Review 2/2: second-new"
    assert_includes out, "completed_reviews=2 approved=2 blocked=0"

    reviewer_calls = json_lines(@reviewer_log)
    assert_equal ["first-new", "second-new"], reviewer_calls.map(&:first)

    task_calls = json_lines(@task_log)
    moves = task_calls.select { |args| args.first == "move" }
    assert_equal [
      ["move", "first-new", "reviewed", "--actor", "avi"],
      ["move", "second-new", "reviewed", "--actor", "avi"]
    ], moves

    assert_equal 4, json_lines(@codex_log).size, "two reviewer subagents per PR"
    assert_operator json_lines(@devops_log).size, :>=, 4, "heartbeat must query again after each PR review"
  end

  def test_fast_mode_launches_multiple_prs_before_resolving_the_wave
    first = task("first-new", created_at: "2026-06-29T12:30:00Z")
    second = task("second-new", created_at: "2026-06-29T12:20:00Z")
    third = task("third-new", created_at: "2026-06-29T12:10:00Z")
    first_reviewed = task("first-new", created_at: "2026-06-29T12:30:00Z",
                                       reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    second_reviewed = task("second-new", created_at: "2026-06-29T12:20:00Z",
                                         reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    third_reviewed = task("third-new", created_at: "2026-06-29T12:10:00Z",
                                       reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])

    write_snapshots(
      snapshot([first, second, third]),
      snapshot([first_reviewed, second_reviewed, third]),
      snapshot([first_reviewed, second_reviewed, third]),
      snapshot([third]),
      snapshot([third_reviewed])
    )

    out, err, status = run_heartbeat("--run", "--fast", "--limit", "3", "--max-agents", "5",
                                     env: { "CODEX_SLEEP" => "0.05" })

    assert status.success?, err
    assert_includes out, "mode=fast"
    assert_includes out, "fast wave: tasks=first-new, second-new"
    assert_includes out, "completed_reviews=3 approved=3 blocked=0"

    reviewer_calls = json_lines(@reviewer_log)
    assert_equal ["first-new", "second-new", "third-new"], reviewer_calls.map(&:first)
    assert_equal 6, json_lines(@codex_log).size, "fast mode still launches two reviewer subagents per PR"

    sequence = json_lines(@sequence_log)
    first_move_index = sequence.index { |entry| entry.first == "task" && entry[1] == "move" }
    assert first_move_index, "expected a task move after reviewer launches"
    codex_before_first_move = sequence.first(first_move_index).count { |entry| entry.first == "codex" }
    assert_equal 4, codex_before_first_move,
                 "fast mode should launch two PR review pairs before resolving the first PR"

    moves = json_lines(@task_log).select { |args| args.first == "move" }
    assert_equal [
      ["move", "first-new", "reviewed", "--actor", "avi"],
      ["move", "second-new", "reviewed", "--actor", "avi"],
      ["move", "third-new", "reviewed", "--actor", "avi"]
    ], moves
  end

  def test_run_mode_places_codex_global_flags_before_exec
    task_record = task("flag-order", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("flag-order", created_at: "2026-06-29T12:00:00Z",
                                  reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([task_record]), snapshot([reviewed]))

    _out, err, status = run_heartbeat("--run", "--limit", "1")

    assert status.success?, err
    args = json_lines(@codex_log).first
    assert_equal ["-a", "never", "-s", "danger-full-access", "exec"], args.first(5)
    exec_index = args.index("exec")
    assert_operator args.index("-a"), :<, exec_index
    assert_operator args.index("-s"), :<, exec_index
    assert_includes args, "-C"
    assert_includes args, "-o"
  end

  def test_blocks_a_pr_when_either_reviewer_requests_changes
    bad = task("bad-pr", created_at: "2026-06-29T12:00:00Z")
    bad_reviewed = task(
      "bad-pr",
      created_at: "2026-06-29T12:00:00Z",
      reports: [report("carl", "request-changes", "Missing regression test"), report("shannon", "merge-ready")]
    )
    write_snapshots(snapshot([bad]), snapshot([bad_reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1")

    assert status.success?, err
    assert_includes out, "blocked=1"
    assert_includes out, "request-changes"
    assert_includes out, "improve PR/task/worktree readiness before submission"

    task_calls = json_lines(@task_log)
    assert_includes task_calls.map(&:first), "block"
    refute_includes task_calls.map(&:first), "move"
    block_call = task_calls.find { |args| args.first == "block" }
    assert_equal "bad-pr", block_call[1]
    assert_includes block_call, "--kind"
    assert_includes block_call, "rework"
  end

  def test_reviewer_prompt_instructs_each_reviewer_to_narrate_as_its_soul
    newest = task("narrated-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("narrated-pr", created_at: "2026-06-29T12:00:00Z",
                                   reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([newest]), snapshot([reviewed]))

    _out, err, status = run_heartbeat("--once")

    assert status.success?, err
    prompts = prompt_files_by_reviewer
    assert_equal %w[carl shannon], prompts.keys.sort, "expected a prompt file per selected reviewer"

    prompts.each do |reviewer_slug, prompt|
      assert_narration_instructions(prompt, reviewer_slug, "narrated-pr")
      assert_includes prompt,
                      "bin/devops-cycle --record-scout-report narrated-pr --scout-agent #{reviewer_slug}",
                      "scout-report recording must remain in the prompt"
    end
  end

  def test_run_mode_delivers_narration_instructions_to_each_spawned_reviewer
    task_record = task("narrated-run", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("narrated-run", created_at: "2026-06-29T12:00:00Z",
                                    reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([task_record]), snapshot([reviewed]))

    _out, err, status = run_heartbeat("--run", "--limit", "1")

    assert status.success?, err
    narrations = json_lines(@narration_log).to_h { |reviewer, _slug, lines| [reviewer, lines] }
    assert_equal %w[carl shannon], narrations.keys.sort, "each spawned reviewer must receive the prompt on stdin"

    narrations.each do |reviewer_slug, lines|
      start_line = lines.find { |line| line.include?("agent-activity start") }
      end_line = lines.find { |line| line.include?("agent-activity end") }
      assert start_line, "#{reviewer_slug} stdin prompt missing bin/agent-activity start"
      assert end_line, "#{reviewer_slug} stdin prompt missing bin/agent-activity end"
      assert_includes start_line, "--category Verify"
      assert_includes start_line, "--agent #{reviewer_slug}"
      assert_includes start_line, "--supervisor avi"
      assert_includes start_line, "--task narrated-run"
      assert_includes end_line, "--outcome"
    end

    moves = json_lines(@task_log).select { |args| args.first == "move" }
    assert_equal [["move", "narrated-run", "reviewed", "--actor", "avi"]], moves,
                 "verdict handoff must remain unchanged"
  end

  def test_dry_run_selects_reviewers_without_recording_intent_or_launching_codex
    newest = task("dry-new", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("dry-new", created_at: "2026-06-29T12:00:00Z",
                               reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([newest]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--once")

    assert status.success?, err
    assert_includes out, "pr-review DRY-RUN"
    assert_includes out, "dry-run: would summon primary review: carl"
    assert_includes out, "dry-run: would summon light review: shannon"
    assert_empty json_lines(@codex_log)
    assert_empty json_lines(@task_log)

    reviewer_call = json_lines(@reviewer_log).first
    assert_equal "dry-new", reviewer_call.first
    assert_includes reviewer_call, "--no-record"
  end

  # [unit] The supervisor selects the primary+light pair, spawns BOTH role
  # reviewers in parallel, and NEVER performs a review itself. Each reviewer is
  # pointed at its own role SOP (pr-review-primary.md / pr-review-light.md), and
  # the reviewer-select step narrates as "select primary+light reviewers", never
  # "summon Avi". (Regression guard for the 3-level supervisor hierarchy.)
  def test_supervisor_spawns_two_role_reviewers_in_parallel_and_never_reviews
    newest = task("role-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("role-pr", created_at: "2026-06-29T12:00:00Z",
                               reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([newest]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1", env: { "CODEX_SLEEP" => "0.05" })
    assert status.success?, err

    # The supervisor narrates reviewer-select as a SELECTION, never as summoning an Avi reviewer.
    assert_includes out, "select primary+light reviewers",
                    "the supervisor narrates the reviewer-select step as a selection"
    refute_match(/summon\s+avi/i, out, "the supervisor never summons an Avi reviewer")

    # Exactly the two SELECTED souls get a prompt — no supervisor/avi review prompt exists.
    prompts = prompt_files_by_reviewer
    assert_equal %w[carl shannon], prompts.keys.sort,
                 "only the two selected souls review; the supervisor never reviews"

    # Each reviewer runs ITS role SOP in ITS role.
    primary = prompts.fetch("carl")
    light = prompts.fetch("shannon")
    assert_includes primary, "as carl, a pr-review primary reviewer"
    assert_includes primary, "docs/agents/agents/avi/sops/pr-review-primary.md"
    refute_includes primary, "pr-review-light.md"
    assert_includes light, "as shannon, a pr-review light reviewer"
    assert_includes light, "docs/agents/agents/avi/sops/pr-review-light.md"
    refute_includes light, "pr-review-primary.md"

    # Both prompts frame Avi as a thin supervisor that never reviews — no #417 "summon"/"nests" framing.
    [primary, light].each do |prompt|
      assert_match(/never reviews code/i, prompt, "the supervisor is framed as a thin gate that never reviews")
      refute_match(/summon/i, prompt)
      refute_match(/nests its reviewers/i, prompt)
    end

    # Both reviewers are spawned BEFORE the supervisor gates the verdict — the
    # parallel sibling structure, not primary-spawns-light.
    sequence = json_lines(@sequence_log)
    move_index = sequence.index { |entry| entry.first == "task" && entry[1] == "move" }
    assert move_index, "expected a supervisor task move after both reviewers ran"
    codex_before_move = sequence.first(move_index).count { |entry| entry.first == "codex" }
    assert_equal 2, codex_before_move,
                 "both role reviewers spawn in parallel before the supervisor collects verdicts"
  end

  # [integration] A full review run (spawn stubbed by the codex fake) attributes
  # the primary and light roles to exactly the souls bin/reviewer-select picked —
  # the selection matches execution end to end (prompt role SOP, soul-attributed
  # narration, and the supervisor's verdict handoff).
  def test_review_run_attributes_primary_and_light_to_the_reviewer_select_pick
    # Override the selection so the pick is unambiguous and different from the default pair.
    write_exec("reviewer-select", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("REVIEWER_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      puts JSON.generate("reviewers" => [
        { "slug" => "jasper", "weight" => "primary" },
        { "slug" => "steffon", "weight" => "light" }
      ])
    RUBY

    newest = task("attr-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("attr-pr", created_at: "2026-06-29T12:00:00Z",
                               reports: [report("jasper", "merge-ready"), report("steffon", "merge-ready")])
    write_snapshots(snapshot([newest]), snapshot([reviewed]))

    _out, err, status = run_heartbeat("--run", "--limit", "1")
    assert status.success?, err

    # The SELECTED souls execute, in the SELECTED roles, each on its role SOP.
    prompts = prompt_files_by_reviewer
    assert_equal %w[jasper steffon], prompts.keys.sort, "the reviewer-select pick is who executes"
    assert_includes prompts.fetch("jasper"), "as jasper, a pr-review primary reviewer"
    assert_includes prompts.fetch("jasper"), "docs/agents/agents/avi/sops/pr-review-primary.md"
    assert_includes prompts.fetch("steffon"), "as steffon, a pr-review light reviewer"
    assert_includes prompts.fetch("steffon"), "docs/agents/agents/avi/sops/pr-review-light.md"

    # Each spawned reviewer narrates its Verify activity attributed to its own soul.
    narrations = json_lines(@narration_log).to_h { |reviewer, _slug, lines| [reviewer, lines] }
    assert_equal %w[jasper steffon], narrations.keys.sort
    narrations.each do |soul, lines|
      start_line = lines.find { |line| line.include?("agent-activity start") }
      assert start_line, "#{soul} must open a soul-attributed activity"
      assert_includes start_line, "--agent #{soul}"
      assert_includes start_line, "--supervisor avi"
      assert_includes start_line, "--task attr-pr"
    end

    # The final verdict handoff is the supervisor's (avi), not a reviewer's.
    moves = json_lines(@task_log).select { |args| args.first == "move" }
    assert_equal [["move", "attr-pr", "reviewed", "--actor", "avi"]], moves
  end

  # [unit] The supervisor announces each parallel spawn with an intent-labeled
  # delegate action — "summon primary review: <soul>" and "summon light review:
  # <soul>" — the deterministic-path echo of the interactive Agent-tool
  # `description`. Two role-tagged, supervisor-emitted spawns are what keep the
  # primary from re-delegating (harden-review-lane-roles).
  def test_supervisor_emits_two_intent_labeled_delegate_actions
    newest = task("labeled-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("labeled-pr", created_at: "2026-06-29T12:00:00Z",
                                  reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([newest]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1", env: { "CODEX_SLEEP" => "0.05" })

    assert status.success?, err
    assert_includes out, "summon primary review: carl",
                    "the supervisor emits a role-tagged delegate action for the primary"
    assert_includes out, "summon light review: shannon",
                    "the supervisor emits a role-tagged delegate action for the light"
    # The label is role-specific: the primary is never announced as a light spawn.
    refute_includes out, "summon light review: carl"
    refute_includes out, "summon primary review: shannon"
    # The supervisor never summons an Avi reviewer — Avi IS the supervisor.
    refute_match(/summon\s+avi/i, out)
  end

  # [unit] The role split is legible in the spawned prompts: the PRIMARY prompt
  # frames it as the review OWNER that runs the gates and DRIVES the verdict; the
  # LIGHT prompt disclaims both. This is the responsibility half of the hardening
  # — primary owns gates + verdict, light is a focused second read that reports up.
  def test_reviewer_prompts_carry_the_primary_light_responsibility_split
    newest = task("split-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("split-pr", created_at: "2026-06-29T12:00:00Z",
                                reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([newest]), snapshot([reviewed]))

    _out, err, status = run_heartbeat("--once")
    assert status.success?, err

    prompts = prompt_files_by_reviewer
    primary = prompts.fetch("carl")
    light = prompts.fetch("shannon")

    # PRIMARY = review owner: runs the gates AND drives the verdict.
    assert_match(/PRIMARY you are the review OWNER/i, primary)
    assert_match(/run the gates/i, primary)
    assert_match(/DRIVE the verdict/i, primary)

    # LIGHT = focused second read: does NOT run the gates, does NOT drive the verdict.
    assert_match(/LIGHT you are a focused second read/i, light)
    assert_match(/do NOT run the gates/i, light)
    assert_match(/do NOT\s+.*drive the verdict/im, light)
    # The light never claims to own/drive the verdict.
    refute_match(/you DRIVE the verdict/i, light)
  end
end

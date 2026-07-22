# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../support/session_env"

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
    @gate_log = File.join(@dir, "gate.log")
    @gh_log = File.join(@dir, "gh.log")
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

    # bin/task fake — logs every call. `review-claim acquire <slug>` exits 10 (held by
    # another session) for a slug in REVIEW_CLAIM_SKIP and 1 (unconfirmed — no session
    # id / board down) for a slug in REVIEW_CLAIM_UNCONFIRMED, else 0. `list --stage
    # submitted --reviewable` prints REVIEWABLE_SLUGS in the real "slug [stage] title"
    # format (+ the "(N task(s))" line the supervisor keys on) when set; every other
    # verb exits 0.
    write_exec("task", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("TASK_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      File.open(ENV.fetch("SEQUENCE_LOG"), "a") { |f| f.puts JSON.generate(["task", *ARGV]) }
      if ARGV[0] == "review-claim" && ARGV[1] == "acquire"
        slug = ARGV[2]
        if ENV.fetch("REVIEW_CLAIM_SKIP", "").split(",").include?(slug)
          STDOUT.puts "review-claim: SKIP \#{slug} (under review by another session)"; exit 10
        end
        if ENV.fetch("REVIEW_CLAIM_UNCONFIRMED", "").split(",").include?(slug)
          STDERR.puts "review-claim: no session id — cannot confirm the claim"; exit 1
        end
      end
      if ARGV[0] == "list" && ARGV.include?("--reviewable") && !ENV.fetch("REVIEWABLE_SLUGS", "").empty?
        slugs = ENV.fetch("REVIEWABLE_SLUGS").split(",")
        slugs.each { |s| puts "\#{s}  [submitted]  \#{s} title" }
        puts "(\#{slugs.length} task(s))"
        exit 0
      end
      puts "task fake: \#{ARGV.join(" ")}"
    RUBY

    # bin/gate fake — captures the supervisor's fire-and-forget G2 gate markers
    # deterministically (the real bin/gate would try the live board from a test).
    write_exec("gate", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("GATE_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
    RUBY

    # gh fake — the accepted-ladder's review-merge shells `gh` (base read, retarget,
    # merge, merge-state). Deterministic + injectable so the review-merge tests never
    # touch a live PR. Defaults: base=accepted (no retarget), merge succeeds.
    #   GH_PR_BASE   — the feat PR's base (default accepted; set "release" to force a retarget)
    #   GH_MERGE_FAIL=1 — `gh pr merge` exits nonzero
    #   GH_EDIT_FAIL=1  — `gh pr edit` (retarget) exits nonzero
    #   GH_PR_STATE  — `gh pr view --json state` value (default OPEN; "MERGED" = crash recovery)
    write_exec("gh", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("GH_LOG"), "a") { |f| f.puts JSON.generate(ARGV) }
      File.open(ENV.fetch("SEQUENCE_LOG"), "a") { |f| f.puts JSON.generate(["gh", *ARGV]) }
      if ARGV[0] == "pr" && ARGV[1] == "view" && ARGV.include?("baseRefName")
        puts ENV.fetch("GH_PR_BASE", "accepted"); exit 0
      end
      if ARGV[0] == "pr" && ARGV[1] == "view" && ARGV.include?("state")
        puts ENV.fetch("GH_PR_STATE", "OPEN"); exit 0
      end
      exit(ENV["GH_EDIT_FAIL"].to_s == "1" ? 1 : 0) if ARGV[0] == "pr" && ARGV[1] == "edit"
      exit(ENV["GH_MERGE_FAIL"].to_s == "1" ? 1 : 0) if ARGV[0] == "pr" && ARGV[1] == "merge"
      exit 0
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
    full_env = SessionEnv.neutralized({
      "DEVOPS_CYCLE_BIN" => File.join(@dir, "devops-cycle"),
      "REVIEWER_SELECT_BIN" => File.join(@dir, "reviewer-select"),
      "TASK_BIN" => File.join(@dir, "task"),
      "CODEX_BIN" => File.join(@dir, "codex"),
      "GATE_BIN" => File.join(@dir, "gate"),
      "GH_BIN" => File.join(@dir, "gh"),
      "GH_LOG" => @gh_log,
      "SNAPSHOT_DIR" => @snapshots,
      "SNAPSHOT_COUNTER" => @counter,
      "DEVOPS_LOG" => @devops_log,
      "REVIEWER_LOG" => @reviewer_log,
      "CODEX_LOG" => @codex_log,
      "TASK_LOG" => @task_log,
      "GATE_LOG" => @gate_log,
      "SEQUENCE_LOG" => @sequence_log,
      "NARRATION_LOG" => @narration_log,
      # The supervisor checks the PR's live CI before spawning reviewers
      # (ci-gate-review-handoff). Default the injection seam to green so the
      # existing review-flow tests stay focused on THEIR subject; a CI-gate test
      # overrides with its own token / per-slug map.
      "PR_REVIEW_CI_STATUS" => "green"
    }.merge(env))

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

  # [integration] Parallel-safe review (the per-task claim REPLACING the per-role
  # stand-down): a task already under LIVE review by ANOTHER session — its
  # `review-claim acquire` returns exit 10 — is SKIPPED (no reviewer-select, no
  # reviewer spawn, no verdict, no released claim it never took) while the unclaimed
  # task in the same wave is reviewed normally. This is what lets many pr-review
  # sessions run at once: each skips only the tasks others hold, never stands down.
  def test_a_task_under_review_by_another_session_is_skipped_and_the_rest_proceed
    taken = task("taken-pr", created_at: "2026-06-29T12:30:00Z")
    free = task("free-pr", created_at: "2026-06-29T12:20:00Z")
    free_reviewed = task("free-pr", created_at: "2026-06-29T12:20:00Z",
                                    reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(
      snapshot([taken, free]),
      snapshot([taken, free_reviewed])
    )

    out, err, status = run_heartbeat(
      "--run", "--fast", "--limit", "2", "--max-agents", "5",
      env: { "REVIEW_CLAIM_SKIP" => "taken-pr", "CODEX_SLEEP" => "0.05" }
    )

    assert status.success?, err
    assert_match(/SKIP taken-pr/, out, "the wave log names the task another session is reviewing")

    # The taken task never reaches reviewer selection or a reviewer spawn.
    reviewer_slugs = json_lines(@reviewer_log).map(&:first)
    refute_includes reviewer_slugs, "taken-pr", "a task under review by another session is skipped"
    assert_equal ["free-pr"], reviewer_slugs, "only the unclaimed task is reviewed"
    assert_equal 2, json_lines(@codex_log).size, "one review pair total — none for the skipped task"

    # Only the free task is resolved (merged → reviewed); the taken task is untouched.
    moves = json_lines(@task_log).select { |a| a.first == "move" }
    assert_equal [["move", "free-pr", "reviewed", "--actor", "avi"]], moves

    # We release ONLY the claim we actually took — never one we skipped.
    releases = json_lines(@task_log).select { |a| a.first == "review-claim" && a[1] == "release" }
    assert_equal ["free-pr"], releases.map { |a| a[2] }, "release only the tasks we claimed, not the skipped one"
  end

  # [integration] The supervisor reviews ONLY on a CONFIRMED claim. A task whose
  # `review-claim acquire` cannot be confirmed (exit 1 — no session id / board down) is
  # NOT reviewed: proceeding on an unconfirmed claim is the double-review the gate
  # exists to prevent. It defers (loudly) while the confirmable task proceeds.
  def test_a_task_with_an_unconfirmable_claim_is_not_reviewed
    unc = task("unconfirmed-pr", created_at: "2026-06-29T12:30:00Z")
    ok = task("ok-pr", created_at: "2026-06-29T12:20:00Z")
    ok_reviewed = task("ok-pr", created_at: "2026-06-29T12:20:00Z",
                                reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([unc, ok]), snapshot([unc, ok_reviewed]))

    out, err, status = run_heartbeat(
      "--run", "--fast", "--limit", "2", "--max-agents", "5",
      env: { "REVIEW_CLAIM_UNCONFIRMED" => "unconfirmed-pr", "CODEX_SLEEP" => "0.05" }
    )

    assert status.success?, err
    assert_match(/unconfirmed-pr: review claim UNCONFIRMED/, out,
                 "the supervisor says loudly it will not review on an unconfirmed claim")

    reviewer_slugs = json_lines(@reviewer_log).map(&:first)
    refute_includes reviewer_slugs, "unconfirmed-pr",
                    "a task whose claim cannot be confirmed is NOT reviewed (no double-review)"
    assert_equal ["ok-pr"], reviewer_slugs, "the confirmable task is reviewed"

    releases = json_lines(@task_log).select { |a| a.first == "review-claim" && a[1] == "release" }
    refute_includes releases.map { |a| a[2] }, "unconfirmed-pr", "never releases a claim it never held"
  end

  # [integration] The supervisor SELECTS from the board's reviewable queue (the
  # operator's headline query) rather than fetching every submitted task and leaning on
  # the claim alone. A submitted task the board reports as NOT reviewable (under review
  # elsewhere) is never even claim-attempted.
  def test_supervisor_reviews_only_the_boards_reviewable_queue
    a = task("queue-a", created_at: "2026-06-29T12:30:00Z")
    b = task("queue-b", created_at: "2026-06-29T12:20:00Z")
    a_reviewed = task("queue-a", created_at: "2026-06-29T12:30:00Z",
                                 reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([a, b]), snapshot([a_reviewed, b]))

    # The board's reviewable queue lists ONLY queue-a; queue-b is under review elsewhere.
    out, err, status = run_heartbeat(
      "--run", "--fast", "--limit", "2", "--max-agents", "5",
      env: { "REVIEWABLE_SLUGS" => "queue-a", "CODEX_SLEEP" => "0.05" }
    )

    assert status.success?, err
    reviewer_slugs = json_lines(@reviewer_log).map(&:first)
    assert_includes reviewer_slugs, "queue-a"
    refute_includes reviewer_slugs, "queue-b", "a task outside the reviewable queue is never attempted"

    acquires = json_lines(@task_log).select { |a| a.first == "review-claim" && a[1] == "acquire" }
    refute_includes acquires.map { |a| a[2] }, "queue-b", "the filtered task isn't even claim-attempted"
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

  # --- dry-run is a PREVIEW, not a review round --------------------------------
  # (regression: dry-run-launches-real-reviewers)
  #
  # `--help` promises a dry-run "previews without launching reviewers or writing
  # tasks". The launch and write halves were honored, but the run did NOT stop
  # there: it fell through into the verdict-resolution path, read the task's
  # scout reports — which are the verdicts of PRIOR review rounds still on the
  # board — and printed them as THIS run's result, retrospective and all
  # ("completed_reviews=1 approved=0 blocked=1" + the stale reviewer summaries).
  # A preview was indistinguishable from a real review, so the operator read it
  # as "my dry-run just burned two reviewer agents".

  # [unit] The dry-run never launches a reviewer AGENT — no launcher process, no
  # reviewer log. The log file only exists as the spawn's stdout redirect, so an
  # empty log set is structural proof that nothing was spawned (not merely that
  # the fake codex recorded nothing).
  def test_dry_run_launches_zero_reviewer_agents
    ready = task("no-spawn", created_at: "2026-06-29T12:00:00Z",
                             reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([ready]))

    out, err, status = run_heartbeat("--once")

    assert status.success?, err
    assert_empty json_lines(@codex_log), "dry-run must not invoke the reviewer launcher"
    assert_empty Dir[File.join(@output, "**", "*.log")],
                 "a spawned reviewer would leave its stdout log behind; dry-run must spawn none"
    assert_empty json_lines(@task_log), "dry-run must not write the board"
    assert_empty json_lines(@gate_log), "dry-run must not write gate markers"

    # The preview is the whole point — it still names the pair it WOULD summon.
    assert_includes out, "dry-run: would summon primary review: carl"
    assert_includes out, "dry-run: would summon light review: shannon"
  end

  # [unit] The dry-run STOPS at the pair it would summon. It must not resolve a
  # verdict from scout reports left by earlier review rounds, must not count a
  # completed/blocked review, and must not echo those stale summaries as if two
  # reviewers had just reported.
  def test_dry_run_stops_at_the_preview_and_never_replays_stale_verdicts
    stale = task(
      "stale-verdict-pr",
      created_at: "2026-06-29T12:00:00Z",
      reports: [
        report("carl", "request-changes", "STALE VERDICT from a previous review round"),
        report("shannon", "merge-ready", "STALE APPROVAL from a previous review round")
      ]
    )
    write_snapshots(snapshot([stale]))

    out, err, status = run_heartbeat("--once")

    assert status.success?, err
    assert_empty json_lines(@codex_log), "no reviewer runs, so no verdict belongs to this run"

    # The preview survives.
    assert_includes out, "dry-run: would summon primary review: carl"
    assert_includes out, "dry-run: would summon light review: shannon"
    assert_includes out, "preview only", "the dry-run says plainly that it stopped at the preview"

    # No verdict is resolved from the board's prior-round reports.
    refute_includes out, "STALE VERDICT from a previous review round",
                    "dry-run must not replay a prior round's scout report as this run's verdict"
    refute_includes out, "STALE APPROVAL from a previous review round"
    refute_match(/^\s*decision=/, out, "dry-run must not print a resolved review decision")

    # The retrospective counts a PREVIEW, never a completed/blocked review.
    assert_match(/previewed=1/, out, "the retrospective reports what the dry-run actually did")
    assert_match(/completed_reviews=0 approved=0 blocked=0/, out,
                 "a dry-run completes, approves and blocks nothing")
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

  # --- supervisor CI gate-zero (ci-gate-review-handoff) -------------------------
  # The builder now submits WITHOUT waiting for CI, so the CI check is pr-review's
  # opening act: BEFORE selecting/spawning the reviewer pair the supervisor reads
  # the PR's live CI (bin/lib/ci_status.rb; PR_REVIEW_CI_STATUS injects — a bare
  # token, a per-slug JSON map, or a raw `gh pr checks --json` array). Red blocks
  # the task back naming the failing checks WITHOUT burning reviewer tokens;
  # pending/none defers to a later wave; green proceeds to spawn.

  # [unit] Red CI: the task is blocked back with the failing checks named, no
  # reviewer is selected or spawned, and the bounce lands as a failed dor_review
  # (gate-zero) attempt.
  def test_red_ci_blocks_the_task_back_before_spawning_reviewers
    red = task("red-pr", created_at: "2026-06-29T12:00:00Z")
    write_snapshots(snapshot([red]))

    out, err, status = run_heartbeat(
      "--run", "--limit", "1",
      env: { "PR_REVIEW_CI_STATUS" => JSON.generate([
        { "name" => "CI / test:system", "state" => "FAILURE", "bucket" => "fail" }
      ]) }
    )

    assert status.success?, err
    assert_includes out, "blocked=1"
    assert_match(/ci=RED/i, out)

    # No reviewer tokens burned: neither selection nor codex spawn happened.
    assert_empty json_lines(@reviewer_log), "red CI must not reach reviewer-select"
    assert_empty json_lines(@codex_log), "red CI must not spawn reviewers"

    # The block names the failing checks.
    block_call = json_lines(@task_log).find { |args| args.first == "block" }
    assert block_call, "expected a task block"
    assert_equal "red-pr", block_call[1]
    assert_includes block_call, "rework"
    feedback = block_call[block_call.index("--feedback") + 1]
    assert_includes feedback, "CI / test:system", "the feedback names the failing checks"

    # The CI bounce is review's gate-zero verdict this round: a failed dor_review
    # attempt records it (the gate-zero home, not a G2 review lane).
    gate_calls = json_lines(@gate_log)
    close = gate_calls.find { |args| args.first == "close" && args.include?("dor_review") }
    assert close, "expected a failed dor_review close for the CI bounce"
    assert_includes close, "--failed"
    assert_includes close, "outcome=ci-red"
    assert_empty gate_calls.select { |args| args.include?("g2a_primary") },
                 "no G2 review-lane gate is written when no reviewer runs"
  end

  # [unit] Pending CI: the task defers to a later wave (existing defer machinery)
  # without spawning reviewers and without blocking the task.
  def test_pending_ci_defers_the_task_without_spawning_reviewers
    waiting = task("waiting-pr", created_at: "2026-06-29T12:00:00Z")
    write_snapshots(snapshot([waiting]))

    out, err, status = run_heartbeat("--once", "--run", env: { "PR_REVIEW_CI_STATUS" => "pending" })

    assert status.success?, err
    assert_includes out, "deferred"
    assert_match(/ci=PENDING/i, out)
    assert_empty json_lines(@codex_log), "pending CI must not spawn reviewers"
    task_verbs = json_lines(@task_log).map(&:first)
    refute_includes task_verbs, "block", "pending CI is a defer, not a bounce"
    refute_includes task_verbs, "move"
  end

  # [integration] Mixed wave via the per-slug map: the green PR gets the normal
  # review pair; the red PR is bounced without a single reviewer spawn.
  def test_mixed_wave_reviews_green_and_bounces_red_by_slug
    red = task("red-pr", created_at: "2026-06-29T12:30:00Z")
    green = task("green-pr", created_at: "2026-06-29T12:20:00Z")
    green_reviewed = task("green-pr", created_at: "2026-06-29T12:20:00Z",
                                      reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(
      snapshot([red, green]),
      snapshot([green_reviewed])
    )

    out, err, status = run_heartbeat(
      "--run", "--fast", "--limit", "2",
      env: { "PR_REVIEW_CI_STATUS" => JSON.generate("red-pr" => "red", "green-pr" => "green"),
             "CODEX_SLEEP" => "0.05" }
    )

    assert status.success?, err
    assert_includes out, "completed_reviews=2 approved=1 blocked=1"

    assert_equal ["green-pr"], json_lines(@reviewer_log).map(&:first),
                 "only the green PR reaches reviewer selection"
    assert_equal 2, json_lines(@codex_log).size, "one review pair total — none for the red PR"

    task_calls = json_lines(@task_log)
    block_call = task_calls.find { |args| args.first == "block" }
    assert_equal "red-pr", block_call[1]
    moves = task_calls.select { |args| args.first == "move" }
    assert_equal [["move", "green-pr", "reviewed", "--actor", "avi"]], moves
  end

  # [integration] Conflicted PR (mergeStateStatus DIRTY): blocked BACK, never
  # deferred. A conflicted PR gets NO GitHub CI at all (GitHub cannot compute the
  # merge commit), so pre-fix it folded into :none → "defer until CI reports" →
  # deferred every wave, forever, with the board showing a healthy submitted task
  # (PR #509, 2026-07-12). The supervisor must treat it like red — an actionable
  # bounce naming the fix — not like pending/none (CI genuinely still coming).
  def test_conflicted_pr_is_blocked_back_not_deferred
    stuck = task("stuck-pr", created_at: "2026-06-29T12:00:00Z")
    write_snapshots(snapshot([stuck]))

    out, err, status = run_heartbeat("--run", "--limit", "1", env: { "PR_REVIEW_CI_STATUS" => "conflicted" })

    assert status.success?, err
    assert_includes out, "blocked=1"
    assert_match(/ci=CONFLICTED/i, out)

    # No reviewer tokens burned — like the red bounce.
    assert_empty json_lines(@reviewer_log), "a conflicted PR must not reach reviewer-select"
    assert_empty json_lines(@codex_log), "a conflicted PR must not spawn reviewers"

    # Blocked back (actionable), NOT deferred (invisible): the feedback names the fix.
    block_call = json_lines(@task_log).find { |args| args.first == "block" }
    assert block_call, "expected a task block, not a defer"
    assert_equal "stuck-pr", block_call[1]
    assert_includes block_call, "rework"
    feedback = block_call[block_call.index("--feedback") + 1]
    assert_match(/conflict/i, feedback)
    assert_match(/rebase|merge release/i, feedback, "the feedback names the fix")
    assert_match(/no.*CI|CI never fires/i, feedback, "the feedback explains WHY deferring would strand it")

    # The bounce records as a failed dor_review (gate-zero) attempt, distinct
    # from the ci-red outcome.
    gate_calls = json_lines(@gate_log)
    close = gate_calls.find { |args| args.first == "close" && args.include?("dor_review") }
    assert close, "expected a failed dor_review close for the conflict bounce"
    assert_includes close, "--failed"
    assert_includes close, "outcome=ci-conflicted"
  end

  # [integration] CI-less PR: blocked BACK like conflicted, never deferred, and the
  # feedback must NOT re-introduce "rebase" vocabulary (round 4, blocker 3 — both
  # lanes). This block feedback is the exact channel this work names as the pollution
  # channel, and round 3 rewrote the remedy to prescribe `merge` because a halted
  # rebase strands the operator. A trailing "push the rebased branch" would undo that
  # rewrite one sentence later, into task feedback a compliant agent then obeys.
  def test_ci_less_pr_is_blocked_back_with_a_remedy_that_never_says_rebase
    stuck = task("ciless-pr", created_at: "2026-06-29T12:00:00Z")
    write_snapshots(snapshot([stuck]))

    out, err, status = run_heartbeat("--run", "--limit", "1", env: { "PR_REVIEW_CI_STATUS" => "ci_less" })

    assert status.success?, err
    assert_includes out, "blocked=1"

    # No reviewer tokens burned — like the red/conflicted bounce.
    assert_empty json_lines(@reviewer_log), "a ci-less PR must not reach reviewer-select"
    assert_empty json_lines(@codex_log), "a ci-less PR must not spawn reviewers"

    block_call = json_lines(@task_log).find { |args| args.first == "block" }
    assert block_call, "expected a task block, not a defer"
    assert_equal "ciless-pr", block_call[1]
    feedback = block_call[block_call.index("--feedback") + 1]
    assert_match(/NO CI WILL RUN/i, feedback, "the feedback names the state")
    # THE regression: no rebase vocabulary reaches task feedback, and no silently
    # halting && chain.
    refute_match(/rebas/i, feedback, "the remedy must not say rebase — round 3 chose merge for recoverability")
    refute_includes feedback, "&&", "no command chain that halts mid-way in task feedback"

    close = json_lines(@gate_log).find { |args| args.first == "close" && args.include?("dor_review") }
    assert close, "expected a failed dor_review close for the ci-less bounce"
    assert_includes close, "--failed"
    assert_includes close, "outcome=ci-less"
  end

  # [unit] An UNVERIFIED CI read (gh/network error) proceeds to spawn — the gate
  # never trades a flaky CI lane for a flaky review loop; the primary's strict
  # gate-zero still holds the authoritative verdict downstream.
  def test_unverified_ci_still_spawns_the_review_pair
    fuzzy = task("fuzzy-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("fuzzy-pr", created_at: "2026-06-29T12:00:00Z",
                                reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([fuzzy]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1", env: { "PR_REVIEW_CI_STATUS" => "unverified" })

    assert status.success?, err
    assert_equal 2, json_lines(@codex_log).size, "unverified CI proceeds to the review pair"
    moves = json_lines(@task_log).select { |args| args.first == "move" }
    assert_equal [["move", "fuzzy-pr", "reviewed", "--actor", "avi"]], moves
    assert_match(/ci=unverified/i, out)
  end

  # --- the accepted-ladder's first rung: review MERGES feat → accepted ----------
  # On a merge-ready verdict the supervisor now merges the feat PR into `accepted`,
  # stamps merged:"accepted", THEN moves the task `reviewed` (the sweep later promotes
  # accepted→release). The order is load-bearing: merge → stamp → move, so a failure
  # can never leave the forbidden (reviewed, unstamped) state. GH_BIN fakes the merge.

  # [integration] Happy path: merge the feat PR into accepted, stamp merged:accepted,
  # move reviewed — IN THAT ORDER.
  def test_merge_ready_merges_feat_into_accepted_then_stamps_then_moves
    ready = task("ladder-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("ladder-pr", created_at: "2026-06-29T12:00:00Z",
                                 reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([ready]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1")
    assert status.success?, err
    assert_includes out, "approved=1"

    # The feat PR was merged into accepted.
    merge_call = json_lines(@gh_log).find { |a| a[0] == "pr" && a[1] == "merge" }
    assert merge_call, "a merge-ready verdict merges the feat PR into accepted"

    # The task was stamped merged:accepted AND moved reviewed.
    task_calls = json_lines(@task_log)
    assert_includes task_calls, ["merged", "ladder-pr", "accepted"], "review stamps merged:accepted"
    moves = task_calls.select { |a| a.first == "move" }
    assert_equal [["move", "ladder-pr", "reviewed", "--actor", "avi"]], moves

    # ORDER across the shared sequence log: merge → stamp → move.
    seq = json_lines(@sequence_log)
    merge_i = seq.index { |e| e[0] == "gh" && e[1] == "pr" && e[2] == "merge" }
    stamp_i = seq.index { |e| e[0] == "task" && e[1] == "merged" }
    move_i  = seq.index { |e| e[0] == "task" && e[1] == "move" }
    assert merge_i && stamp_i && move_i, "expected merge, stamp, and move all to run"
    assert merge_i < stamp_i, "merge the feat PR onto accepted BEFORE stamping merged:accepted"
    assert stamp_i < move_i, "stamp merged:accepted BEFORE moving reviewed (invariant: never reviewed+unstamped)"
  end

  # [unit] A mis-based feat PR (base != accepted) is RETARGETED to accepted, then
  # merged — the review-merge self-heals instead of stranding a PR opened on release.
  def test_merge_ready_retargets_a_misbased_feat_pr_then_merges
    ready = task("misbased-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("misbased-pr", created_at: "2026-06-29T12:00:00Z",
                                   reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([ready]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1", env: { "GH_PR_BASE" => "release" })
    assert status.success?, err

    gh = json_lines(@gh_log)
    edit = gh.find { |a| a[0] == "pr" && a[1] == "edit" && a.include?("accepted") }
    assert edit, "a mis-based feat PR (base release) is retargeted to accepted before merging"
    assert gh.find { |a| a[0] == "pr" && a[1] == "merge" }, "then it is merged"
    assert_match(/retarget misbased-pr PR base release/, out)

    moves = json_lines(@task_log).select { |a| a.first == "move" }
    assert_equal [["move", "misbased-pr", "reviewed", "--actor", "avi"]], moves
  end

  # [unit] A feat-merge FAILURE leaves the task submitted+unstamped — the invariant
  # reviewed ⟺ code-on-accepted. No merged stamp, no move to reviewed.
  def test_merge_failure_leaves_the_task_submitted_and_unstamped
    ready = task("broken-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("broken-pr", created_at: "2026-06-29T12:00:00Z",
                                 reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([ready]), snapshot([reviewed]))

    # Merge fails AND the PR is still OPEN (not an interrupted prior-run merge).
    out, err, status = run_heartbeat("--run", "--limit", "1",
                                     env: { "GH_MERGE_FAIL" => "1", "GH_PR_STATE" => "OPEN" })
    assert status.success?, err
    assert_includes out, "tool_failures=1"
    assert_includes out, "approved=0"

    verbs = json_lines(@task_log).map(&:first)
    refute_includes verbs, "move", "a failed feat merge must NOT move the task reviewed"
    refute_includes verbs, "merged", "and must NOT stamp merged:accepted (invariant: reviewed ⟺ code-on-accepted)"
  end

  # [unit] Crash recovery: a `gh pr merge` that fails because the PR ALREADY merged on
  # a prior interrupted run (whose stamp/move died) is NOT a bounce — the review-merge
  # reads the PR state, sees MERGED, and proceeds to stamp + move.
  def test_merge_failure_but_pr_already_merged_proceeds_to_stamp_and_move
    ready = task("recovered-pr", created_at: "2026-06-29T12:00:00Z")
    reviewed = task("recovered-pr", created_at: "2026-06-29T12:00:00Z",
                                    reports: [report("carl", "merge-ready"), report("shannon", "merge-ready")])
    write_snapshots(snapshot([ready]), snapshot([reviewed]))

    out, err, status = run_heartbeat("--run", "--limit", "1",
                                     env: { "GH_MERGE_FAIL" => "1", "GH_PR_STATE" => "MERGED" })
    assert status.success?, err
    assert_includes out, "already merged on GitHub (interrupted prior run)"

    task_calls = json_lines(@task_log)
    assert_includes task_calls, ["merged", "recovered-pr", "accepted"]
    moves = task_calls.select { |a| a.first == "move" }
    assert_equal [["move", "recovered-pr", "reviewed", "--actor", "avi"]], moves
  end
end

# frozen_string_literal: true

# [integration] What bin/task does with two answers the board gives on a write:
# the `warnings` array beside `data` (guard catalog row 10.1), and a pr_urls map
# keyed by the repo each url names (row 10.3). Drives the real binary against a
# one-shot stub board; no Rails, no network.
#
#   ruby -Itest test/lib/task_cli_board_answers_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskCliBoardAnswersTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  HUB = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836"
  TURF = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # Returns [requests, out, err, status]. Every task read and write answers
  # `{ data: record }`, with `warnings` beside it when given.
  def run_task(args, devops: { "kind" => "feature" }, warnings: nil, top: {})
    @sandbox ||= Dir.mktmpdir("task-answers-sandbox")
    body = { "data" => { "slug" => "demo-task", "stage" => "building", "title" => "Demo Task",
                         "metadata" => { "devops" => devops } }.merge(top) }
    body["warnings"] = warnings if warnings
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests, JSON.generate(body)) }
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox)))
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, task_payload)
    loop do
      client = server.accept
      request_line = client.gets or break
      method, path = request_line.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }
      payload = path == "/api/v1/auth" ? JSON.generate("token" => "stub-token") : task_payload
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed
  end

  # The board's silent-claim flag (Task::SilentClaim) is printed by `show`.
  def test_show_prints_the_silent_claim_flag_the_board_raised
    silent = { "kind" => "review", "holder" => "carl", "last_write_at" => "2026-10-11T08:00:00Z",
               "seconds" => 2700, "label" => "silent 30m+" }
    _requests, out, err, status = run_task(%w[show demo-task], top: { "stage" => "submitted", "silent_claim" => silent })

    assert status.success?, err
    assert_includes out, "silent 30m+: review claim held by carl, nothing written on the task for 45m " \
                         "(last write 2026-10-11T08:00:00Z)"

    _requests, out, = run_task(%w[show demo-task], top: { "silent_claim" => nil })
    refute_includes out, "silent 30m+", "control: no flag, no line"
  end

  def test_a_write_prints_each_warning_the_board_answers_and_succeeds
    advice = "title is 9 words; 3-5 reads best on the board (put detail in agent_context)"
    _requests, _out, err, status = run_task(%w[update demo-task --kind chore], warnings: [advice])

    assert status.success?, err
    assert_includes err, "warning: #{advice}"
  end

  # The control: the same write with no warnings prints none.
  def test_a_write_the_board_answers_plainly_prints_no_warning
    _requests, _out, err, status = run_task(%w[update demo-task --kind chore])

    assert status.success?, err
    refute_match(/^warning:/, err)
  end

  # The url decides the key, so a pair typed under the wrong repo joins the stored
  # map beside that repo's own entry instead of replacing it.
  def test_pr_url_for_keys_a_pair_by_the_repo_its_url_names
    requests, _out, err, status = run_task(
      ["update", "demo-task", "--pr-url-for", "mcritchie-studio=#{TURF}"],
      devops: { "kind" => "feature", "pr_urls" => { "mcritchie-studio" => HUB } }
    )

    assert status.success?, err
    patch = requests.reverse.find { |r| r[:method] == "PATCH" }
    refute_nil patch, "expected a PATCH for the update"
    assert_equal({ "mcritchie-studio" => HUB, "turf-monster" => TURF },
                 JSON.parse(patch[:body]).dig("devops", "pr_urls"))
    assert_includes err, "is filed under turf-monster, the repo the url names"
  end

  def test_pr_url_for_under_its_own_repo_says_nothing
    requests, _out, err, status = run_task(["update", "demo-task", "--pr-url-for", "turf-monster=#{TURF}"])

    assert status.success?, err
    patch = requests.reverse.find { |r| r[:method] == "PATCH" }
    assert_equal({ "turf-monster" => TURF }, JSON.parse(patch[:body]).dig("devops", "pr_urls"))
    refute_match(/is filed under/, err)
  end

  # --- the cost and time lines (task-show-prints-cost) -----------------------
  #
  # [unit] `show` renders the API's total_cost, cost_by_stage and
  # durations_by_stage (Task::CostSummary) as a `cost:` and a `time:` line, terse
  # and --verbose, and `--json` passes them through. A stage that never happened
  # arrives as null and prints `-`, never `0s` or `$0.00`. They live here, not in a
  # file of their own, because every task_* file maps to bin/task's capped lane.

  COST_FIELDS = {
    "total_cost" => 12.3456,
    "cost_by_stage" => { "build" => 8.0, "review" => 3.0956, "deploy" => 1.25, "other" => nil },
    "durations_by_stage" => { "design" => 7380, "build" => 2700, "review" => 45, "assemble" => nil, "ship" => nil }
  }.freeze

  def test_show_prints_the_cost_and_time_lines_terse_and_verbose
    [%w[show demo-task], %w[show demo-task --verbose]].each do |args|
      form = args.join(" ")
      _requests, out, err, status = run_task(args, top: COST_FIELDS)

      assert status.success?, "#{form}: #{err}"
      assert_includes out, "  cost: $12.35  build $8.00 · review $3.10 · deploy $1.25\n", form
      assert_includes out, "  time: design 2h 3m · build 45m · review 45s · assemble - · ship -\n", form
      refute_match(/other/, out, "#{form}: an unpriced `other` bucket stays off the line")
    end
  end

  def test_a_priced_other_bucket_is_printed
    fields = COST_FIELDS.merge("cost_by_stage" => COST_FIELDS["cost_by_stage"].merge("other" => 0.5))
    _requests, out, _err, status = run_task(%w[show demo-task], top: fields)

    assert status.success?
    assert_includes out, "deploy $1.25 · other $0.50\n"
  end

  # The control: a task nobody measured and nothing moved prints dashes, not zeros.
  def test_show_prints_dashes_for_an_unmeasured_task
    _requests, out, _err, status = run_task(
      %w[show demo-task],
      top: { "total_cost" => nil,
             "cost_by_stage" => { "build" => nil, "review" => nil, "deploy" => nil, "other" => nil },
             "durations_by_stage" => { "design" => nil, "build" => nil, "review" => nil, "assemble" => nil, "ship" => nil } }
    )

    assert status.success?
    assert_includes out, "  cost: -  build - · review - · deploy -\n"
    assert_includes out, "  time: design - · build - · review - · assemble - · ship -\n"
  end

  def test_show_json_carries_the_cost_fields
    _requests, out, _err, status = run_task(%w[show demo-task --json], top: COST_FIELDS)

    assert status.success?
    data = JSON.parse(out)
    assert_in_delta 12.3456, data["total_cost"], 0.00001
    assert_equal COST_FIELDS["cost_by_stage"], data["cost_by_stage"]
    assert_equal COST_FIELDS["durations_by_stage"], data["durations_by_stage"]
  end

  # An older board, or a PATCH echo, carries none of the fields: no lines at all,
  # rather than a `cost: -` claiming the task was measured and came up empty.
  def test_show_prints_no_cost_line_when_the_record_lacks_the_fields
    _requests, out, _err, status = run_task(%w[show demo-task])

    assert status.success?
    refute_match(/^  cost:/, out)
    refute_match(/^  time:/, out)
  end

  def test_elapsed_rolls_up_to_days
    _requests, out, = run_task(%w[show demo-task],
                    top: COST_FIELDS.merge("durations_by_stage" => { "design" => 273_600 }))

    assert_includes out, "time: design 3d 4h · build -"
  end
end

# frozen_string_literal: true

# [unit] task-show-prints-cost: `bin/task show` renders the API's total_cost,
# cost_by_stage and durations_by_stage as a `cost:` and a `time:` line, in the
# terse view and in --verbose, and `--json` passes the fields through. A stage
# that never happened arrives as null and prints `-`, never `0s` or `$0.00`.
# Drives the real binary against a one-shot stub board; no Rails, no network.
#
#   ruby -Itest test/lib/task_cli_cost_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskCliCostTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)

  COST_FIELDS = {
    "total_cost" => 12.3456,
    "cost_by_stage" => { "build" => 8.0, "review" => 3.0956, "deploy" => 1.25, "other" => nil },
    "durations_by_stage" => { "design" => 7380, "build" => 2700, "review" => 45, "assemble" => nil, "ship" => nil }
  }.freeze

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # Returns [out, err, status]. Every read answers `{ data: record }`.
  def run_task(args, top: {})
    @sandbox ||= Dir.mktmpdir("task-cost-sandbox")
    body = { "data" => { "slug" => "demo-task", "stage" => "building", "title" => "Demo Task",
                         "metadata" => { "devops" => { "kind" => "feature" } } }.merge(top) }
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new { serve(server, JSON.generate(body)) }
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox)))
    Open3.capture3(env, RbConfig.ruby, BIN, *args)
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, task_payload)
    loop do
      client = server.accept
      request_line = client.gets or break
      path = request_line.split(" ")[1]
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      client.read(headers["content-length"].to_i) if headers["content-length"]
      payload = path == "/api/v1/auth" ? JSON.generate("token" => "stub-token") : task_payload
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed
  end

  def test_show_prints_the_cost_and_time_lines_terse_and_verbose
    [%w[show demo-task], %w[show demo-task --verbose]].each do |args|
      form = args.join(" ")
      out, err, status = run_task(args, top: COST_FIELDS)

      assert status.success?, "#{form}: #{err}"
      assert_includes out, "  cost: $12.35  build $8.00 · review $3.10 · deploy $1.25\n", form
      assert_includes out, "  time: design 2h 3m · build 45m · review 45s · assemble - · ship -\n", form
      refute_match(/other/, out, "#{form}: an unpriced `other` bucket stays off the line")
    end
  end

  def test_a_priced_other_bucket_is_printed
    fields = COST_FIELDS.merge("cost_by_stage" => COST_FIELDS["cost_by_stage"].merge("other" => 0.5))
    out, _err, status = run_task(%w[show demo-task], top: fields)

    assert status.success?
    assert_includes out, "deploy $1.25 · other $0.50\n"
  end

  # The control: a task nobody measured and nothing moved prints dashes, not zeros.
  def test_show_prints_dashes_for_an_unmeasured_task
    out, _err, status = run_task(
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
    out, _err, status = run_task(%w[show demo-task --json], top: COST_FIELDS)

    assert status.success?
    data = JSON.parse(out)
    assert_in_delta 12.3456, data["total_cost"], 0.00001
    assert_equal COST_FIELDS["cost_by_stage"], data["cost_by_stage"]
    assert_equal COST_FIELDS["durations_by_stage"], data["durations_by_stage"]
  end

  # An older board, or a PATCH echo, carries none of the fields: no lines at all,
  # rather than a `cost: -` claiming the task was measured and came up empty.
  def test_show_prints_no_cost_line_when_the_record_lacks_the_fields
    out, _err, status = run_task(%w[show demo-task])

    assert status.success?
    refute_match(/^  cost:/, out)
    refute_match(/^  time:/, out)
  end

  def test_elapsed_rolls_up_to_days
    out, = run_task(%w[show demo-task],
                    top: COST_FIELDS.merge("durations_by_stage" => { "design" => 273_600 }))

    assert_includes out, "time: design 3d 4h · build -"
  end
end

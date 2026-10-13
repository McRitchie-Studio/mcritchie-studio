# frozen_string_literal: true

# [integration] bin/ship-clock end to end: the real script, a localhost stub board (a
# real socket, real Net::HTTPResponses) and a stub `gh` on SHIP_CLOCK_GH_BIN, so the
# whole path runs — token mint, the task row, task and release gate runs, the T0 note,
# `gh run list`, `gh pr view`, a red run's job log — with nothing real at either
# boundary. The unit file next door (ship_clock_test.rb) covers the arithmetic; this
# one proves the CLI reads the records it claims to and writes only where it says.
#
#   ruby -Itest test/lib/ship_clock_cli_test.rb
require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "csv"
require_relative "../support/session_env"

class ShipClockCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/ship-clock", __dir__)
  SLUG = "demo-ship"
  RELEASE = "rel-20261013-demo01"
  REPO = "McRitchie-Studio/mcritchie-studio"

  TASK = {
    "slug" => SLUG, "title" => "Demo Ship", "stage" => "shipped", "branch" => "feat/#{SLUG}",
    "release_slug" => RELEASE, "pr_url" => "https://github.com/#{REPO}/pull/9001",
    "created_at" => "2026-10-13T14:23:14Z", "started_at" => "2026-10-13T14:23:31Z",
    "submitted_at" => "2026-10-13T14:43:35Z", "reviewed_at" => "2026-10-13T14:44:59Z",
    "assembled_at" => "2026-10-13T15:03:35Z", "completed_at" => "2026-10-13T15:18:35Z", "archived_at" => nil
  }.freeze

  T0_NOTE = { "created_at" => "2026-10-13T14:15:02Z", "activity_type" => "comment",
              "description" => "ship-clock T0 2026-10-13T14:15:00Z (08:15:00 MDT)",
              "metadata" => { "kind" => "ship_clock_t0", "t0" => "2026-10-13T14:15:00Z", "estimated" => false } }.freeze

  def gate(key, attempt, from, to, success, metadata: {})
    { "key" => key, "attempt" => attempt, "started_at" => "2026-10-13T#{from}Z",
      "finished_at" => "2026-10-13T#{to}Z", "success" => success,
      "sops" => success ? [] : [{ "sop" => "ci", "result" => "fail" }], "metadata" => metadata }
  end

  def task_gates = [gate("dor", 1, "14:32:43", "14:32:44", false), gate("dor", 2, "14:43:34", "14:43:34", true)]

  def release_gates
    [gate("g3_candidate", 1, "14:50:25", "15:04:12", true),
     gate("g4_ship", 1, "15:06:04", "15:09:22", false, metadata: { "aborted" => true }),
     gate("g4_ship", 2, "15:11:41", "15:18:09", true)]
  end

  # What the stub gh answers, keyed by its first argument words.
  def gh_fixture
    {
      "run list" => [{ "databaseId" => 501, "headSha" => "7a86edaaaa", "conclusion" => "failure",
                       "createdAt" => "2026-10-13T14:27:00Z", "startedAt" => "2026-10-13T14:27:00Z",
                       "updatedAt" => "2026-10-13T14:34:48Z" },
                     { "databaseId" => 502, "headSha" => "5bf00c9aaa", "conclusion" => "success",
                       "createdAt" => "2026-10-13T14:35:00Z", "startedAt" => "2026-10-13T14:35:00Z",
                       "updatedAt" => "2026-10-13T14:43:18Z" }].to_json,
      "pr view" => { "createdAt" => "2026-10-13T14:26:53Z", "mergedAt" => "2026-10-13T14:44:55Z" }.to_json,
      "run view" => { "jobs" => [{ "databaseId" => 7001, "name" => "ci / rails (2)", "conclusion" => "failure" },
                                 { "databaseId" => 7002, "name" => "ci / lint", "conclusion" => "success" }] }.to_json,
      "api" => "2026-10-13T14:31:10.1Z Failure:\n" \
               "2026-10-13T14:31:10.2Z StackViewTest#test_team_tier_price [test/views/price_card_sample_test.rb:32]:\n" \
               "2026-10-13T14:31:10.3Z Expected \"$1,500\" to include \"$900\".\n" \
               "2026-10-13T14:31:10.4Z\n"
    }
  end

  def setup
    @dir = Dir.mktmpdir("ship-clock-cli")
    File.write(File.join(@dir, "gh.json"), JSON.generate(gh_fixture))
    @gh = File.join(@dir, "gh")
    File.write(@gh, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(#{File.join(@dir, "gh-calls.log").inspect}, "a") { |f| f.puts(ARGV.join(" ")) }
      fixture = JSON.parse(File.read(#{File.join(@dir, "gh.json").inspect}))
      key = ARGV.first == "api" ? "api" : ARGV.first(2).join(" ")
      abort("stub gh: no fixture for \#{ARGV.join(' ')}") unless fixture.key?(key)
      print fixture[key]
    RUBY
    FileUtils.chmod(0o755, @gh)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def gh_calls = File.exist?(File.join(@dir, "gh-calls.log")) ? File.readlines(File.join(@dir, "gh-calls.log"), chomp: true) : []

  def run_clock(args, task: [200, TASK], notes: [T0_NOTE])
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests, task, notes) }
    env = SessionEnv.neutralized(
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}", "AGENT_API_SECRET" => "test-secret",
      "AGENT_API_TOKEN" => nil, "SHIP_CLOCK_GH_BIN" => @gh, "SHIP_CLOCK_HOME" => File.join(@dir, "home"), "TZ" => "UTC"
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args, chdir: @dir)
    [out, err, status, requests]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, task, notes)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }
      code, payload =
        if path.start_with?("/api/v1/auth") then [200, { "token" => "stub-token" }]
        elsif path == "/api/v1/tasks/#{SLUG}" then [task[0], { "data" => task[1] }]
        elsif path.start_with?("/api/v1/tasks/") then [404, { "error" => "not found" }]
        elsif path == "/api/v1/gates/task/#{SLUG}" then [200, { "data" => task_gates }]
        elsif path == "/api/v1/gates/release/#{RELEASE}" then [200, { "data" => release_gates }]
        elsif path.start_with?("/api/v1/activities") && method == "GET" then [200, { "data" => notes }]
        elsif path.start_with?("/api/v1/activities") then [201, { "data" => { "slug" => "activity-1" } }]
        else [500, { "error" => "unexpected #{method} #{path}" }]
        end
      text = JSON.generate(payload)
      client.write("HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  # --- report --------------------------------------------------------------

  def test_report_json_rebuilds_the_timeline_from_every_record
    out, err, status, requests = run_clock(["report", SLUG, "--json"])

    assert status.success?, err
    report = JSON.parse(out)
    assert_equal "2026-10-13T14:15:00Z", report["t0"], "T0 comes from the stamped board note"
    assert_equal "stamped", report["t0_source"]
    assert_equal "2026-10-13T15:18:09Z", report["production_at"]
    assert_equal [3789, 1259, 1713, 817], report.values_at("total_s", "hands_on_s", "wait_s", "rework_s")
    assert_equal 1, report["red_ci_rounds"]
    red = report["rework"].find { |r| r["kind"] == "red CI" }
    assert_equal "ci / rails (2): test/views/price_card_sample_test.rb:32", red["cause"], "the cause is read from the red job's log"

    paths = requests.map { |r| r[:path] }
    assert_includes paths, "/api/v1/gates/release/#{RELEASE}"
    assert_includes paths, "/api/v1/gates/task/#{SLUG}"
    assert(requests.none? { |r| r[:method] != "GET" && !r[:path].start_with?("/api/v1/auth") }, "report writes nothing")
    assert(gh_calls.any? { |c| c.start_with?("run list --repo #{REPO} --branch feat/#{SLUG}") }, gh_calls.inspect)
    assert(gh_calls.any? { |c| c == "api repos/#{REPO}/actions/jobs/7001/logs" }, "only the FAILED job's log is read")
    refute(gh_calls.any? { |c| c.include?("jobs/7002") })
  end

  def test_report_prints_the_stage_table_and_the_split
    out, err, status, = run_clock(["report", SLUG])

    assert status.success?, err
    assert_match(/T0 08:15:00 MDT \(stamped\) → production 09:18:09 MDT \(g4_ship\)/, out)
    assert_match(/09:09:22\s+54m22s\s+production ship #1 failed/, out)
    assert_match(/hands-on\s+20m59s/, out)
    assert_match(/rework\s+13m37s.*1 red CI round/, out)
  end

  def test_report_on_a_missing_task_refuses
    _out, err, status, = run_clock(["report", "no-such-task"])

    refute status.success?
    assert_match(/no task no-such-task/, err)
  end

  def test_a_failed_board_read_refuses_rather_than_reporting_a_hole
    _out, err, status, = run_clock(["report", SLUG], task: [500, { "error" => "boom" }])

    refute status.success?
    assert_match(/HTTP 500/, err)
  end

  def test_a_failed_gh_read_refuses_rather_than_filing_ci_time_as_hands_on
    File.write(File.join(@dir, "gh.json"), JSON.generate(gh_fixture.except("run list")))
    _out, err, status, = run_clock(["report", SLUG])

    refute status.success?
    assert_match(/gh run list failed/, err)
  end

  # --- record --------------------------------------------------------------

  def test_record_appends_one_ledger_row_and_replaces_it_on_a_rerun
    ledger = File.join(@dir, "ledger.csv")
    _out, err, status, = run_clock(["record", SLUG, "--ledger", ledger, "--note", "first"])
    assert status.success?, err
    _out, err, status, = run_clock(["record", SLUG, "--ledger", ledger, "--note", "second"])
    assert status.success?, err

    rows = CSV.read(ledger)
    assert_equal %w[date slug t0 t0_source production_at total_min hands_on_min wait_min rework_min
                    red_ci_rounds notes], rows.first
    assert_equal 2, rows.size, "a re-run replaces the slug's row instead of adding a second answer"
    assert_equal ["2026-10-13", SLUG, "2026-10-13T14:15:00Z", "stamped", "2026-10-13T15:18:09Z",
                  "63.2", "21.0", "28.6", "13.6", "1"], rows[1].first(10)
    assert rows[1][10].end_with?("second"), rows[1][10]
  end

  # --- start ---------------------------------------------------------------

  def test_start_posts_a_t0_note_on_an_existing_task
    out, err, status, requests = run_clock(["start", SLUG, "--at", "2026-10-13T14:15:00Z"], notes: [])

    assert status.success?, err
    assert_match(/T0 stamped on #{SLUG}: 2026-10-13T14:15:00Z/, out)
    post = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }
    body = JSON.parse(post[:body])
    assert_equal SLUG, body["task_slug"]
    assert_equal({ "kind" => "ship_clock_t0", "t0" => "2026-10-13T14:15:00Z", "estimated" => false }, body["metadata"])
  end

  def test_start_refuses_a_second_stamp_without_restamp
    _out, err, status, requests = run_clock(["start", SLUG])

    assert_equal 3, status.exitstatus
    assert_match(/already has a T0/, err)
    assert(requests.none? { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" })
  end

  def test_start_before_the_task_exists_holds_t0_locally_then_moves_it_onto_the_board
    out, err, status, = run_clock(["start", "future-task", "--at", "2026-10-13T14:10:00Z"])
    assert status.success?, err
    assert_match(/held locally/, out)
    pending = File.join(@dir, "home", "future-task.json")
    assert File.exist?(pending)

    # The task now exists under that slug: the second start carries the HELD time.
    FileUtils.mv(pending, File.join(@dir, "home", "#{SLUG}.json"))
    _out, err, status, requests = run_clock(["start", SLUG], notes: [])
    assert status.success?, err
    body = JSON.parse(requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/activities" }[:body])
    assert_equal "2026-10-13T14:10:00Z", body.dig("metadata", "t0"), "the prompt-time stamp wins over now"
    refute File.exist?(File.join(@dir, "home", "#{SLUG}.json")), "the held stamp is cleared once on the board"
  end

  # --- argv ----------------------------------------------------------------

  def test_help_and_unknown_flags_never_reach_the_board
    out, _err, status, requests = run_clock(["record", SLUG, "--help"])
    assert status.success?
    assert_match(/usage: bin\/ship-clock start/, out)
    assert_empty requests

    _out, err, status, requests = run_clock(["record", SLUG, "--bogus"])
    refute status.success?
    assert_match(/invalid option: --bogus/, err)
    assert_empty requests
  end
end

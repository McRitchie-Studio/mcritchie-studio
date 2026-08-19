# frozen_string_literal: true

# Integration test for bin/devops-reconcile — the CLI driven end to end across
# its real I/O boundary, with every EXTERNAL mocked: the board is a local HTTP
# stub, and `gh`, `bin/review-autopilot` and `bin/task` are shims on the child's
# PATH / cwd. The pure decision is covered by test/lib/seam_reconcile_test.rb.
#
#   ruby -Itest test/lib/devops_reconcile_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "open3"
require "json"
require "socket"
require "tmpdir"
require "fileutils"
require "rbconfig"

class DevopsReconcileCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/devops-reconcile", __dir__)

  # --- board stub -------------------------------------------------------------

  def with_board(tasks_by_stage)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { serve(server, tasks_by_stage) }
    yield port
  ensure
    server&.close
    thread&.kill
  end

  def serve(server, tasks_by_stage)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      _verb, path, = line.split(" ")
      while (h = client.gets) && h.strip != ""; end

      body =
        if path.start_with?("/api/v1/auth")
          { "token" => "stub-token" }
        else
          stage = path[/stage=([a-z]+)/, 1]
          { "data" => tasks_by_stage.fetch(stage, []) }
        end.to_json

      client.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
  rescue StandardError
    nil
  end

  # --- external shims ---------------------------------------------------------

  # A cwd containing bin/ shims (the CLI calls `bin/review-autopilot` and
  # `bin/task` by RELATIVE path) plus a PATH dir holding `gh`.
  def with_shims(gh_json:, autopilot: "", task_field: "accepted")
    Dir.mktmpdir("reconcile-cli") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      calls = File.join(root, "calls.log")

      write_shim(File.join(root, "bin", "review-autopilot"), <<~SH)
        #!/bin/sh
        printf '%s' '#{autopilot}'
      SH

      # Records every invocation so the test can assert WHAT was healed.
      write_shim(File.join(root, "bin", "task"), <<~SH)
        #!/bin/sh
        echo "task $@" >> "#{calls}"
        if [ "$1" = "field" ]; then printf '%s' '#{task_field}'; fi
        exit 0
      SH

      write_shim(File.join(root, "gh"), <<~SH)
        #!/bin/sh
        printf '%s' '#{gh_json}'
      SH

      yield root, calls
    end
  end

  def write_shim(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def run_cli(root, port, *args)
    env = {
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "PATH" => "#{root}:#{ENV["PATH"]}"
    }
    Open3.capture3(env, RbConfig.ruby, BIN, *args, chdir: root)
  end

  def task(slug:, stage:, pr: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/1", merged: "")
    { "slug" => slug, "stage" => stage, "merged" => merged,
      "metadata" => { "devops" => { "pr_url" => pr } } }
  end

  GH_MERGED = { state: "MERGED", statusCheckRollup: [{ conclusion: "SUCCESS" }] }.to_json
  GH_OPEN_GREEN = { state: "OPEN", statusCheckRollup: [{ conclusion: "SUCCESS" }] }.to_json

  # --- usage ------------------------------------------------------------------

  def test_refuses_without_a_seam
    with_shims(gh_json: GH_MERGED) do |root, _calls|
      with_board({}) do |port|
        _out, err, status = run_cli(root, port)
        assert_equal 2, status.exitstatus
        assert_match(/--seam is required/, err)
      end
    end
  end

  def test_refuses_an_unknown_seam
    with_shims(gh_json: GH_MERGED) do |root, _calls|
      with_board({}) do |port|
        _out, err, status = run_cli(root, port, "--seam", "not-a-sop")
        assert_equal 2, status.exitstatus
        assert_match(/must be one of/, err)
      end
    end
  end

  # --- the headline: a merged PR whose stamp never landed ---------------------

  def test_reports_stamp_lost_without_healing_by_default
    tasks = { "submitted" => [task(slug: "lost-stamp", stage: "submitted")], "building" => [] }
    with_shims(gh_json: GH_MERGED) do |root, calls|
      with_board(tasks) do |port|
        out, _err, status = run_cli(root, port, "--seam", "pr-review", "--json")
        assert_equal 0, status.exitstatus, "must never block"

        payload = JSON.parse(out)
        finding = payload["findings"].first
        assert_equal "lost-stamp", finding["slug"]
        assert_equal "stamp_lost", finding["anomaly"]
        assert_equal "heal", finding["disposition"]
        assert_empty payload["healed"], "no --heal means no write"
        refute File.exist?(calls), "bin/task must not be called without --heal"
      end
    end
  end

  def test_heal_stamps_and_reads_back
    tasks = { "submitted" => [task(slug: "lost-stamp", stage: "submitted")], "building" => [] }
    with_shims(gh_json: GH_MERGED) do |root, calls|
      with_board(tasks) do |port|
        out, _err, status = run_cli(root, port, "--seam", "pr-review", "--heal", "--json")
        assert_equal 0, status.exitstatus

        healed = JSON.parse(out)["healed"]
        assert_equal 1, healed.size
        assert_equal "lost-stamp", healed.first["slug"]
        assert healed.first["ok"], "read-back should confirm the stamp"

        log = File.read(calls)
        assert_match(/task merged lost-stamp accepted/, log)
        assert_match(/task move lost-stamp reviewed/, log)
      end
    end
  end

  # A heal that does NOT read back as `accepted` must report failure, not success
  # — the write is never trusted on its own.
  def test_heal_that_does_not_read_back_is_reported_failed
    tasks = { "submitted" => [task(slug: "lost-stamp", stage: "submitted")], "building" => [] }
    with_shims(gh_json: GH_MERGED, task_field: "") do |root, _calls|
      with_board(tasks) do |port|
        out, _err, status = run_cli(root, port, "--seam", "pr-review", "--heal", "--json")
        assert_equal 0, status.exitstatus
        refute JSON.parse(out)["healed"].first["ok"]
      end
    end
  end

  # --- verdict-stranded never merges ------------------------------------------

  def test_verdict_stranded_reports_and_never_heals
    tasks = { "submitted" => [task(slug: "stranded", stage: "submitted")], "building" => [] }
    with_shims(gh_json: GH_OPEN_GREEN, autopilot: "stranded refused pr #1\n") do |root, calls|
      with_board(tasks) do |port|
        out, _err, status = run_cli(root, port, "--seam", "pr-review", "--heal", "--json")
        assert_equal 0, status.exitstatus

        payload = JSON.parse(out)
        assert_equal "verdict_stranded", payload["findings"].first["anomaly"]
        assert_equal "report", payload["findings"].first["disposition"]
        assert_empty payload["healed"], "a stranded verdict must never be auto-merged"
        refute File.exist?(calls), "no board write for a report-only finding"
      end
    end
  end

  # --- seam scoping -----------------------------------------------------------

  # `--seam qa-release` reads `reviewed` only, so a submitted-stage anomaly is
  # simply not this SOP's business.
  def test_seam_scopes_the_fetch_and_the_findings
    tasks = {
      "submitted" => [task(slug: "lost-stamp", stage: "submitted")],
      "reviewed" => [task(slug: "held", stage: "reviewed", merged: "")]
    }
    with_shims(gh_json: GH_MERGED) do |root, _calls|
      with_board(tasks) do |port|
        out, _err, = run_cli(root, port, "--seam", "qa-release", "--json")
        slugs = JSON.parse(out)["findings"].map { |f| f["slug"] }
        assert_equal %w[held], slugs
      end
    end
  end

  # --- never blocks -----------------------------------------------------------

  def test_exits_zero_with_no_findings
    with_shims(gh_json: GH_MERGED) do |root, _calls|
      with_board({ "reviewed" => [] }) do |port|
        out, _err, status = run_cli(root, port, "--seam", "qa-release")
        assert_equal 0, status.exitstatus
        assert_match(/nothing stranded/, out)
      end
    end
  end

  # An unreadable `gh` leaves the evidence :unknown, and the safety rule says an
  # unknown can never become a heal.
  def test_unreadable_pr_state_produces_no_heal
    tasks = { "submitted" => [task(slug: "unreadable", stage: "submitted")], "building" => [] }
    Dir.mktmpdir("reconcile-nogh") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      write_shim(File.join(root, "bin", "review-autopilot"), "#!/bin/sh\nexit 1\n")
      write_shim(File.join(root, "bin", "task"), "#!/bin/sh\nexit 0\n")
      write_shim(File.join(root, "gh"), "#!/bin/sh\nexit 1\n") # gh fails
      with_board(tasks) do |port|
        out, _err, status = run_cli(root, port, "--seam", "pr-review", "--heal", "--json")
        assert_equal 0, status.exitstatus
        payload = JSON.parse(out)
        assert_empty payload["findings"]
        assert_empty payload["healed"]
      end
    end
  end
end

# frozen_string_literal: true

# Boots bin/reviewer-select end-to-end — it loads the Rails app — against a
# --file task payload, proving the CLI WIRING: it reads the task's devops shape +
# risk tags, calls ReviewerSelector, and emits a machine-readable decision with a
# primary+light pair that excludes the QA owner. The selection LOGIC itself (domain
# fit, tiebreak, graceful degradation) is unit-tested in
# test/services/reviewer_selector_test.rb; this is the script regression guard.
#
# Run directly:  ruby -Itest test/lib/reviewer_select_test.rb
# Also picked up by the normal `bin/rails test` sweep.
require "minitest/autorun"
require "json"
require "tmpdir"
require "socket"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "../support/session_env"

class ReviewerSelectCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/reviewer-select", __dir__)

  # One sandboxed write root per test — see run_board below for what it prevents.
  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("reviewer-select-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # Runs reviewer-select against an in-memory devops payload, returns [out, code].
  # stderr is discarded: under `bin/rails test` the subprocess inherits bundler's
  # env and emits rubygems warnings that would otherwise corrupt the stdout parse.
  # SessionEnv.neutralized: the child must name NO agent session (see
  # test/support/session_env.rb) — bin/reviewer-select branches on SessionIdentity.
  def select(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "cli-sample", "metadata" => { "devops" => devops }
      ))
      env = SessionEnv.neutralized("RAILS_ENV" => "test")
      out = IO.popen(env, "#{BIN} --file #{path} #{args.join(" ")} 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  def test_json_decision_is_machine_readable
    out, code = select({ "shape" => "backend", "risk_tags" => ["solana"] }, "--json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    refute_nil line, "expected a JSON object on stdout, got:\n#{out}"
    decision = JSON.parse(line)

    assert_equal %w[primary light], decision["reviewers"].map { |r| r["weight"] }, "one primary + one light"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "two distinct seniors"
    refute_includes decision["candidates"], "avi", "the QA owner (avi) is excluded (no self-gating)"
    assert(decision["ranked"].all? { |c| c["roll"].is_a?(Numeric) }, "the tiebreak rolls are emitted (auditable)")
  end

  def test_human_output_names_the_pair_and_the_excluded_qa_owner
    out, code = select("shape" => "onchain")
    assert_equal 0, code, out
    assert_match(/PRIMARY\s+carl/, out, "Carl is the standing primary on every PR")
    assert_match(/LIGHT\s+jasper/, out, "an onchain shape puts the Web3 senior in the light seat")
    assert_match(/excluded:\s+avi/, out)
    assert_match(/tiebreak \(auditable/, out)
  end

  def test_specialist_builder_recorded_on_the_task_is_excluded_from_the_light
    # devops.built_by is what the board JSON carries (the CLI builds an in-memory
    # task from it) — a specialist builder must drop out of the light pool.
    out, code = select({ "shape" => "ui-only", "built_by" => "shannon" }, "--json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal "carl", decision["reviewers"].first["slug"], "Carl is the standing primary"
    refute_includes decision["candidates"], "shannon", "the recorded builder is out of the light pool"
    assert_equal "shannon", decision["builder"]
    assert_equal "shannon", decision["excluded_builder"]
  end

  def test_human_output_names_the_excluded_builder
    out, code = select("shape" => "ui-only", "built_by" => "shannon")
    assert_equal 0, code, out
    assert_match(/excluded:\s+avi/, out, "the QA owner still leads the excluded line")
    assert_match(/shannon \(builder/, out, "the specialist builder is named on the excluded line")
  end

  def test_builder_flag_overrides_the_recorded_builder
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--builder shannon --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal "shannon", decision["builder"], "--builder wins over devops.built_by"
    refute_includes decision["candidates"], "shannon"
  end

  # --- busy exclusion (--busy): agents mid-build/review on OTHER tasks ----------

  def test_busy_souls_and_the_specialist_builder_are_omitted_from_the_light_end_to_end
    # The auto-read specialist builder (built_by=shannon) AND the --busy soul both
    # drop out of the LIGHT pool; Carl owns the primary seat and a pair still forms —
    # no manual --builder flag.
    out, code = select({ "shape" => "backend", "built_by" => "shannon" }, "--busy jasper --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal "carl", decision["reviewers"].first["slug"], "Carl is the standing primary"
    assert_equal "shannon", decision["excluded_builder"], "built_by auto-excluded from the light (no --builder)"
    assert_equal ["jasper"], decision["excluded_busy"], "the --busy soul is excluded from the light"
    pair = decision["reviewers"].map { |r| r["slug"] }
    assert_equal 2, pair.uniq.size, "a pair still forms"
    # shannon (builder) + jasper (busy) are out; steffon is eligible again (avi is the
    # QA owner now), so the light is one of {steffon, alex}.
    %w[shannon jasper].each { |s| refute_includes pair, s, "#{s} is not the light reviewer" }
    assert_includes %w[steffon alex], pair.last, "the light is one of the remaining specialists"
  end

  def test_busy_filter_keeps_a_pair_rather_than_starve_the_pool
    # built_by carl → Carl yields the primary seat, so BOTH seats come from the
    # light pool; marking the rest busy can't drop below a formable pair — the
    # least-bad busy souls are KEPT eligible (starve guard).
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--busy shannon,jasper,alex --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "a pair survives over-exclusion"
    assert decision["kept_busy"].any?, "the starve guard kept the least-bad busy souls eligible"
  end

  def test_human_output_names_the_excluded_busy_souls
    out, code = select({ "shape" => "backend" }, "--busy jasper")
    assert_equal 0, code, out
    assert_match(/jasper \(busy/, out, "a busy soul is named on the excluded line")
  end

  # --- recording flags (unit): --file mode is offline, so the CLI never records,
  # and the auditable pick/tiebreak block is byte-identical with or without the
  # opt-out flag — the recording change must not perturb the advisory output. ---

  # The auditable block the operator reads: the tiebreak header down through PR.
  def decision_block(out)
    out[/tiebreak \(auditable.*/m]
  end

  def test_file_mode_is_always_advisory_and_records_nothing
    out, code = select({ "shape" => "backend" }, "--json")
    assert_equal 0, code, out
    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    refute JSON.parse(line)["intent_recorded"], "--file mode is offline → never records (even by default)"
  end

  def test_no_record_leaves_the_pick_and_tiebreak_output_unchanged
    default, c1 = select("shape" => "backend")            # recording is the default
    no_record, c2 = select({ "shape" => "backend" }, "--no-record")
    assert_equal 0, c1, default
    assert_equal 0, c2, no_record
    refute_nil decision_block(default), "the tiebreak block is present"
    assert_equal decision_block(default), decision_block(no_record),
      "--no-record must not perturb the seeded pick/tiebreak output"
  end

  def test_recording_flags_all_parse_and_exit_zero_back_compat
    # --record is the legacy synonym (now the default), --no-record / --dry / --dry-run opt out.
    %w[--record --no-record --dry --dry-run].each do |flag|
      out, code = select({ "shape" => "backend" }, flag)
      assert_equal 0, code, "#{flag} should parse and exit 0:\n#{out}"
      assert_match(/PRIMARY/, out, "#{flag} still prints the pick")
    end
  end

  # --- board recording (integration): a localhost stub board, no real network ---
  # Mirrors test/lib/task_cli_test.rb's TCPServer stub. Runs bin/reviewer-select in
  # BOARD mode (no --file) against canned auth + task-GET + intent-POST endpoints,
  # proving the DEFAULT run writes the review intent — exactly once, with the picked
  # pair — and that --no-record/--dry suppress it, all without touching prod.
  BOARD_SLUG = "cli-board-sample"

  # Runs bin/reviewer-select <slug> <args> against a one-shot stub board; returns
  # [recorded_requests, stdout, status]. stderr is dropped (it carries bundler /
  # rubygems warnings under the test sweep, never the asserted output).
  # `busy_payload` overrides the body served for the --busy-auto board query
  # (GET /api/v1/tasks?stage=building) with a raw string, so a test can serve
  # what an unreadable answer actually looks like. Returns stderr as a FOURTH
  # element — the busy-set degradation is announced there, and the callers above
  # destructure three, which stays valid.
  def run_board(devops, *args, busy_payload: nil)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, devops, busy_payload) }

    # The board path SEEDS a per-session usage baseline (bin/reviewer-select's
    # seed_review_usage_baseline). Un-neutralized, a run from a live agent session
    # would seed it against the OPERATOR'S real session — writing into the real
    # .agents/task-usage. SessionEnv.neutralized keeps the child session-less.
    #
    # That is necessary but NOT sufficient, and the real store carries the proof:
    # 58 baseline rows keyed by BOARD_SLUG ("cli-board-sample") sit in 58 of the
    # operator's live session files — written by this very test before the
    # neutralizer landed (`bin/task usage-audit` lists them). A guarantee that
    # holds only while nobody opts a session back in is a guarantee waiting to
    # lapse. So the write root is PINNED too, and TASK_USAGE_SANDBOX (armed
    # process-wide by test/support/task_usage_sandbox.rb) makes an unpinned child
    # ABORT rather than fall back to the real store. Belt and braces, on purpose.
    env = SessionEnv.neutralized(
      {
        "TASK_API_BASE" => "http://127.0.0.1:#{port}",
        "AGENT_API_SECRET" => "test-secret",
        "RAILS_ENV" => "test"
      }.merge(TaskUsageSandboxEnv.child_env(sandbox_root))
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, BOARD_SLUG, *args)
    [requests, out, status, err]
  ensure
    server&.close
    thread&.join(1)
  end

  # Minimal HTTP/1.1 stub: records each request, returns canned JSON. The CLI opens
  # one connection per call (auth, the task GET, then the intent POST).
  def serve(server, requests, devops, busy_payload = nil)
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
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, body: body }

      payload = response_for(method, path, devops, busy_payload)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path, devops, busy_payload = nil)
    return JSON.generate("token" => "stub-token") if path == "/api/v1/auth"
    return busy_payload if busy_payload && path.include?("stage=building")
    if method == "POST" && path == "/api/v1/tasks/#{BOARD_SLUG}/intent"
      return JSON.generate("data" => { "slug" => BOARD_SLUG })
    end

    JSON.generate("data" => { "slug" => BOARD_SLUG, "metadata" => { "devops" => devops } })
  end

  def intent_posts(requests)
    requests.select { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks/#{BOARD_SLUG}/intent" }
  end

  def json_decision(out)
    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    refute_nil line, "expected a JSON object on stdout, got:\n#{out}"
    JSON.parse(line)
  end

  def test_default_board_run_records_exactly_one_review_intent
    requests, out, status = run_board({ "shape" => "backend" }, "--json")
    assert_equal 0, status.exitstatus, out

    posts = intent_posts(requests)
    assert_equal 1, posts.size, "the default run posts exactly one review intent"

    body = JSON.parse(posts.first[:body])
    assert_equal "reviewed", body["to_stage"], "the intent targets the reviewed stage"
    assert_equal %w[primary light], body["reviewers"].map { |r| r["weight"] }, "one primary + one light"
    refute_includes body["reviewers"].map { |r| r["slug"] }, "avi", "the QA owner (avi) is never recorded"

    decision = json_decision(out)
    assert_equal decision["reviewers"].map { |r| r["slug"] }, body["reviewers"].map { |r| r["slug"] },
      "the recorded pair is exactly the printed pick (primary/light order included)"
    assert decision["intent_recorded"], "the decision reports the intent was recorded"
  end

  def test_no_record_suppresses_the_review_intent
    requests, out, status = run_board({ "shape" => "backend" }, "--no-record", "--json")
    assert_equal 0, status.exitstatus, out
    assert_equal 0, intent_posts(requests).size, "--no-record writes no intent"
    refute json_decision(out)["intent_recorded"], "--no-record reports no intent recorded"
  end

  def test_dry_run_suppresses_the_review_intent
    requests, out, status = run_board({ "shape" => "backend" }, "--dry", "--json")
    assert_equal 0, status.exitstatus, out
    assert_equal 0, intent_posts(requests).size, "--dry is advisory only — writes nothing"
  end

  def test_record_flag_is_a_back_compat_synonym_for_the_default
    requests, out, status = run_board({ "shape" => "backend" }, "--record", "--json")
    assert_equal 0, status.exitstatus, out
    assert_equal 1, intent_posts(requests).size, "the legacy --record flag still records (now the default)"
  end

  # --- --busy-auto: the fail-open is kept, its SILENCE is not -------------------
  #
  # `in_flight_busy` degrades to an empty busy set on any read failure, on
  # purpose — a board hiccup must never abort the pick. But `Array(res["data"])`
  # gave an UNREADABLE answer and an IDLE BENCH the same value with no signal, so
  # a degraded pick was indistinguishable from a real one and could hand a review
  # to a soul already mid-build. The pick still proceeds; it now SAYS it is
  # degraded.

  def test_an_unreadable_busy_read_still_picks_but_announces_the_degradation
    _requests, out, status, err = run_board({ "shape" => "backend" }, "--busy-auto", "--json",
                                            busy_payload: "<html>502 Bad Gateway</html>")

    assert_equal 0, status.exitstatus, "the fail-open is intact — --busy-auto never aborts the pick"
    assert_equal 2, json_decision(out)["reviewers"].size, "a pair still forms"
    assert_includes err, "busy-auto: could not read who is mid-build"
    assert_includes err, "DEGRADED pick, not an idle bench"
  end

  def test_a_healthy_busy_read_is_silent
    # The control: the warning must fire on an unreadable answer, not on every run.
    _requests, out, status, err = run_board({ "shape" => "backend" }, "--busy-auto", "--json",
                                            busy_payload: JSON.generate("data" => []))

    assert_equal 0, status.exitstatus, out
    refute_includes err, "busy-auto: could not read", "a genuinely idle bench raises no alarm"
  end
end

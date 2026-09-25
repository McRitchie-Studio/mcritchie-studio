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
# bin/pr-review reads WHICH exit-10 refusal this was off the refusal's own lead phrase.
# That coupling is asserted here, against the LIVE text — see the two arm tests below.
require_relative "../../bin/lib/reviewer_select_skip"

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

  # Same as #select but KEEPS stderr, so the refusal text is assertable.
  def select_verbose(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "cli-sample", "metadata" => { "devops" => devops }
      ))
      env = SessionEnv.neutralized("RAILS_ENV" => "test")
      out = IO.popen(env, "#{BIN} --file #{path} #{args.join(" ")} 2>&1", &:read)
      [out, $?.exitstatus]
    end
  end

  # The refusal's explanatory body, minus the templated command lines that carry the
  # task slug — comparing whole outputs would differ on the slug alone.
  def refusal_body(out)
    out.lines.reject { |l| l.include?("bin/reviewer-select") || l.include?("bin/task") }.join
  end

  # --- fail CLOSED on an unknown builder (builder-stamp-misses-reviewer-guard) ---

  def test_refuses_to_select_when_the_builder_is_unknown
    # THE DEFECT: a blank built_by used to mean "exclude nobody" and the tool
    # rolled a reviewer anyway — once picking Carl to review Carl's own PR. An
    # absent fact must refuse, not default to the permissive answer.
    out, code = select_verbose("shape" => "backend")

    refute_equal 0, code, "an unknown builder must NOT exit success:\n#{out}"
    assert_match(/refus/i, out, "the refusal says so out loud")
    assert_match(/--builder/, out, "and names the way to resolve it")
    refute_match(/^PRIMARY\s/, out, "no pair is offered on a refusal")
  end

  def test_refusal_emits_no_decision_in_json_mode
    out, code = select_verbose({ "shape" => "backend" }, "--json")

    refute_equal 0, code
    refute out.lines.any? { |l| l.strip.start_with?("{") && l.include?("\"reviewers\"") },
      "a refusal emits no machine-readable pick a caller could act on:\n#{out}"
  end

  def test_a_known_builder_still_selects
    out, code = select({ "shape" => "backend", "built_by" => "shannon" }, "--json")
    assert_equal 0, code, out

    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal "shannon", decision["builder"]
    refute_includes decision["candidates"], "shannon", "the known builder is excluded from the pool"
  end

  def test_an_explicit_no_builder_assertion_lifts_the_refusal
    out, code = select({ "shape" => "backend" }, "--builder none --json")
    assert_equal 0, code, out

    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal true, decision["builder_known"], "the caller ASSERTED no soul built this"
    assert_nil decision["builder"]
    assert_equal 2, decision["reviewers"].size
  end

  def test_json_decision_is_machine_readable
    out, code = select({ "shape" => "backend", "risk_tags" => ["solana"] }, "--builder none --json")
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
    out, code = select({ "shape" => "onchain" }, "--builder none")
    assert_equal 0, code, out
    assert_match(/PRIMARY\s+carl/, out, "Carl is the standing primary on every PR")
    assert_match(/LIGHT\s+jasper/, out, "an onchain shape puts the Web3 senior in the light seat")
    assert_match(/excluded:\s+avi/, out)
    assert_match(/tiebreak \(auditable/, out)
  end

  # --- the seat line states the mechanism that seated the soul, not an inference ---
  # (selector-picks-fit-zero-light). Driven from the exact measured payload: a docs
  # shape with one soul on the needed domains (xan, fit 2) and everyone else at 0.

  def test_the_standing_primary_seat_never_claims_a_tiebreak
    out, code = select({ "shape" => "docs", "built_by" => "steffon" })
    assert_equal 0, code, out

    primary = out.lines.find { |l| l.start_with?("PRIMARY") }
    light = out.lines.find { |l| l.start_with?("LIGHT") }
    refute_nil primary, "expected a PRIMARY seat line:\n#{out}"
    refute_nil light, "expected a LIGHT seat line:\n#{out}"

    assert_match(/PRIMARY\s+carl/, primary, "Carl is the standing primary on a docs PR")
    assert_match(/standing primary — seated by role/, primary,
      "the seat says WHY it was seated — the role, which is the mechanism #pair actually used")
    refute_match(/tiebreak/, primary,
      "he is never ranked and never rolled; a tiebreak claim here read as a coin toss beating a fit-2 soul")
    refute_match(/roll \d/, primary, "and no roll is printed for a seat that was never rolled")

    assert_match(/LIGHT\s+xan/, light, "the docs soul takes the light seat")
    assert_match(/fit 2/, light, "the seat states its fit score")
    assert_match(/top domain fit/, light, "and the mechanism that won it")
  end

  def test_the_decision_json_carries_each_seats_basis
    out, code = select({ "shape" => "docs", "built_by" => "steffon" }, "--json")
    assert_equal 0, code, out

    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    primary, light = decision["reviewers"]
    assert_equal "standing_primary", primary["basis"], "a machine reader gets the mechanism too"
    assert_nil primary["roll"], "a seat that was never rolled carries no roll, not a 0.0 placeholder"
    assert_equal "domain_fit", light["basis"]
    assert_equal 2, light["fit"]
  end

  def test_a_mixed_fit_pool_ranks_into_the_primary_seat_when_carl_yields
    # Same payload, one variable flipped: Carl is the author, so he yields and BOTH
    # seats come from the ranked list. The docs soul then takes PRIMARY at fit 2 —
    # which is what proves the fit-0 primary above is policy, not a blind seat.
    out, code = select({ "shape" => "docs", "built_by" => "carl" })
    assert_equal 0, code, out

    primary = out.lines.find { |l| l.start_with?("PRIMARY") }
    assert_match(/PRIMARY\s+xan/, primary, "fit decides the primary seat wherever it is allowed to")
    assert_match(/fit 2/, primary)
    assert_match(/top domain fit/, primary, "and the seat names fit as the mechanism")
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
    assert_match(/shannon \(author/, out, "the specialist author is named on the excluded line")
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
    # QA owner now), so the light is one of {steffon, xan}.
    %w[shannon jasper].each { |s| refute_includes pair, s, "#{s} is not the light reviewer" }
    assert_includes %w[steffon xan], pair.last, "the light is one of the remaining specialists"
  end

  def test_busy_filter_keeps_a_pair_rather_than_starve_the_pool
    # built_by carl → Carl yields the primary seat, so BOTH seats come from the
    # light pool; marking the rest busy can't drop below a formable pair — the
    # least-bad busy souls are KEPT eligible (starve guard).
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--busy shannon,jasper,xan --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "a pair survives over-exclusion"
    assert decision["kept_busy"].any?, "the starve guard kept the least-bad busy souls eligible"
  end

  def test_human_output_names_the_excluded_busy_souls
    out, code = select({ "shape" => "backend" }, "--busy jasper --builder none")
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
    out, code = select({ "shape" => "backend" }, "--builder none --json")
    assert_equal 0, code, out
    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    refute JSON.parse(line)["intent_recorded"], "--file mode is offline → never records (even by default)"
  end

  def test_no_record_leaves_the_pick_and_tiebreak_output_unchanged
    default, c1 = select({ "shape" => "backend" }, "--builder none")   # recording is the default
    no_record, c2 = select({ "shape" => "backend" }, "--builder none --no-record")
    assert_equal 0, c1, default
    assert_equal 0, c2, no_record
    refute_nil decision_block(default), "the tiebreak block is present"
    assert_equal decision_block(default), decision_block(no_record),
      "--no-record must not perturb the seeded pick/tiebreak output"
  end

  def test_recording_flags_all_parse_and_exit_zero_back_compat
    # --record is the legacy synonym (now the default), --no-record / --dry / --dry-run opt out.
    %w[--record --no-record --dry --dry-run].each do |flag|
      out, code = select({ "shape" => "backend", "built_by" => "shannon" }, flag)
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
  # Two agent sessions, so a test can drive the SAME task from DIFFERENT live
  # instances — the whole point of the review claim (two-primaries-reviewed-one-pr).
  SESSION_A = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
  SESSION_B = "bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb"

  # Starts ONE stub board and yields a runner, so a test can drive SEVERAL
  # bin/reviewer-select invocations against the SAME board state. That is what "two
  # selects against one task" actually requires: the second run must meet the claim the
  # first one took, which a fresh server per invocation could never show.
  # `run.call(*args, session:)` returns [out, status, err]; `requests` accumulates
  # across every run, so an assertion can count writes for the WHOLE episode.
  # `review_payload` is the MID-REVIEW half of --busy-auto's board read
  # (GET /api/v1/tasks?stage=submitted&full=1) — the half that did not exist until
  # busy-auto-misses-mid-review. Like `busy_payload` it is a RAW string, so a test can
  # serve what an unreadable answer actually looks like.
  #
  # `self_review: true` makes the stub board answer EVERY review-claim POST with the
  # no-self-review refusal (TaskReviewClaim.acquire's first line — it fires before the
  # row lock, so no holder is ever taken). It is the SECOND arm of exit 10, and the one
  # bin/pr-review used to mis-name; see the coupling tests below.
  def with_board(devops, busy_payload: nil, review_payload: nil, self_review: false)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    claim = self_review ? { self_review: true } : {}
    thread = Thread.new { serve(server, requests, devops, busy_payload, claim, review_payload) }

    # THE BOARD PATH SEEDS A PER-SESSION USAGE BASELINE (bin/reviewer-select's
    # seed_review_usage_baseline), and the operator's real store carries the proof of
    # what that costs when it escapes: 58 baseline rows keyed by BOARD_SLUG
    # ("cli-board-sample") sat in 58 of the operator's live session files, written by
    # this very test before the neutralizer landed (`bin/task usage-audit` lists them).
    #
    # So the child gets a FAKE session, never the ambient one. SessionEnv.neutralized
    # strips CLAUDE_CODE_SESSION_ID / CODEX_THREAD_ID and this merge puts a fixed,
    # obviously-synthetic id back — the opt-in SessionEnv documents. What was dangerous
    # was resolving the OPERATOR'S live session, not naming a session at all, and
    # naming one is now load-bearing: bin/reviewer-select takes a review CLAIM, a claim
    # is held by a LIVE INSTANCE, and a session-less child can name none — so without
    # this the board path would go advisory and never be exercised.
    #
    # The seat belt is unchanged and still does the real work: the write root is PINNED
    # (TaskUsageSandboxEnv.child_env) and TASK_USAGE_SANDBOX — armed process-wide by
    # test/support/task_usage_sandbox.rb — makes an unpinned child ABORT rather than
    # fall back to the real store. A guarantee that held only while nobody opted a
    # session back in was a guarantee waiting to lapse; this is the lapse, and the pin
    # is what makes it safe.
    runner = lambda do |*args, session: SESSION_A|
      env = SessionEnv.neutralized(
        {
          "TASK_API_BASE" => "http://127.0.0.1:#{port}",
          "AGENT_API_SECRET" => "test-secret",
          "RAILS_ENV" => "test",
          "CLAUDE_CODE_SESSION_ID" => session,
          # Pinned so the nonce is DATA, not a walk of the live process tree — which
          # under `bin/rails test` would find the operator's own agent process and
          # make two runs share an identity by accident.
          "TASK_CLAIM_NONCE" => "nonce-#{session}"
        }.merge(TaskUsageSandboxEnv.child_env(sandbox_root))
      )
      out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, BOARD_SLUG, *args)
      [out, status, err]
    end
    yield runner, requests
  ensure
    server&.close
    thread&.join(1)
  end

  def run_board(devops, *args, busy_payload: nil, review_payload: nil)
    with_board(devops, busy_payload: busy_payload, review_payload: review_payload) do |run, requests|
      out, status, err = run.call(*args)
      return [requests, out, status, err]
    end
  end

  # Minimal HTTP/1.1 stub: records each request, returns canned JSON. The CLI opens
  # one connection per call (auth, the task GET, the review-claim POST, then the
  # intent POST). `claim` is the stub's one piece of STATE — see review_claim_response.
  def serve(server, requests, devops, busy_payload = nil, claim = {}, review_payload = nil)
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

      payload = response_for(method, path, devops, busy_payload, body, claim, review_payload)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path, devops, busy_payload = nil, body = "", claim = {}, review_payload = nil)
    return JSON.generate("token" => "stub-token") if path == "/api/v1/auth"
    return busy_payload if busy_payload && path.include?("stage=building")
    return review_payload if review_payload && path.include?("stage=submitted")
    if method == "POST" && path == "/api/v1/tasks/#{BOARD_SLUG}/review_claim"
      return review_claim_response(body, claim)
    end
    if method == "POST" && path == "/api/v1/tasks/#{BOARD_SLUG}/intent"
      return JSON.generate("data" => { "slug" => BOARD_SLUG })
    end

    JSON.generate("data" => { "slug" => BOARD_SLUG, "metadata" => { "devops" => devops } })
  end

  # The stub's lease math, deliberately the same SHAPE as TaskReviewClaim.acquire:
  # unclaimed OR the same live instance (session + nonce) ⇒ acquired; a DIFFERENT live
  # instance ⇒ refused, with a holder block for the skip message. That compare-and-set
  # is the only server behaviour these CLI tests depend on, and the REAL implementation
  # — the row lock, the TTL, the self-review backstop — is pinned where it lives, in
  # test/models/task_review_claim_test.rb. Keeping the stub this thin is the point: a
  # stub that re-implemented the lease would start passing for reasons the board does
  # not share.
  def review_claim_response(body, claim)
    sent = begin
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end
    who = [sent["session"].to_s, sent["nonce"].to_s]

    # The self-review refusal is checked FIRST because the real one is: it returns
    # before the row lock, so nothing is claimed and the holder block is the EMPTY row.
    # A reader who expects a holder here is reading the wrong arm — that is the point.
    if claim[:self_review]
      return JSON.generate("data" => { "acquired" => false, "disposition" => "self_review",
                                       "holder" => { "task_slug" => BOARD_SLUG, "session" => nil,
                                                     "live" => false } })
    end

    if claim.empty? || claim[:who] == who
      disposition = claim.empty? ? "unclaimed" : "same_instance"
      claim[:who] = who
      claim[:agent] = sent["reviewer"].to_s
      claim[:label] = sent["label"].to_s
      JSON.generate("data" => { "acquired" => true, "disposition" => disposition,
                                "holder" => holder_hash(claim) })
    else
      JSON.generate("data" => { "acquired" => false, "disposition" => "held_by_other",
                                "holder" => holder_hash(claim) })
    end
  end

  # Mirrors TaskReviewClaim#holder_info — the keys the refusal message reads.
  def holder_hash(claim)
    {
      "task_slug" => BOARD_SLUG, "session" => claim[:who].to_a.first,
      "label" => claim[:label], "agent" => claim[:agent],
      "acquired_at" => "2026-09-21T20:15:00Z", "expires_at" => "2026-09-21T23:40:00Z",
      "heartbeat_age" => 12, "live" => true
    }
  end

  def intent_posts(requests)
    requests.select { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks/#{BOARD_SLUG}/intent" }
  end

  def claim_posts(requests)
    requests.select { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks/#{BOARD_SLUG}/review_claim" }
  end

  def json_decision(out)
    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    refute_nil line, "expected a JSON object on stdout, got:\n#{out}"
    JSON.parse(line)
  end

  def test_default_board_run_records_exactly_one_review_intent
    requests, out, status = run_board({ "shape" => "backend", "built_by" => "shannon" }, "--json")
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

  def test_a_refusal_records_no_review_intent
    # The load-bearing half of failing closed: refusing must also refuse to WRITE.
    # A recorded intent is what the board (and the next reviewer) reads as "these
    # two are on it" — a blind pick must never reach it.
    requests, out, status = run_board({ "shape" => "backend" }, "--json")

    refute_equal 0, status.exitstatus, out
    assert_equal 0, intent_posts(requests).size, "a refused selection records nothing"
  end

  def test_no_record_suppresses_the_review_intent
    requests, out, status = run_board({ "shape" => "backend", "built_by" => "shannon" }, "--no-record", "--json")
    assert_equal 0, status.exitstatus, out
    assert_equal 0, intent_posts(requests).size, "--no-record writes no intent"
    refute json_decision(out)["intent_recorded"], "--no-record reports no intent recorded"
  end

  def test_dry_run_suppresses_the_review_intent
    requests, out, status = run_board({ "shape" => "backend", "built_by" => "shannon" }, "--dry", "--json")
    assert_equal 0, status.exitstatus, out
    assert_equal 0, intent_posts(requests).size, "--dry is advisory only — writes nothing"
  end

  # --- TWO SELECTS, ONE TASK (two-primaries-reviewed-one-pr) -------------------
  #
  # MEASURED 2026-09-21, PR #1516: two sessions selected the same task, both pairs were
  # carl+steffon, and the pair that reached merge-ready was seconds from merging a tree
  # the OTHER pair had already bounced for a blocker it had missed. Only a pre-merge
  # board re-read stopped the bad merge.
  #
  # The defect was a SEAM, not a race in the claim: bin/reviewer-select recorded review
  # INTENT and never touched the claim at all, while `Task.reviewable` keys only on a
  # live claim row. So the board painted "under review" off a claim-less intent and every
  # gate still read FREE. Selection now ACQUIRES or REFUSES; the tests below pin both
  # halves, plus the one that would make the cure worse than the disease.

  def test_a_second_session_selecting_the_same_task_is_REFUSED
    devops = { "shape" => "backend", "built_by" => "shannon" }
    with_board(devops) do |run, requests|
      first_out, first_status, = run.call("--json", session: SESSION_A)
      assert_equal 0, first_status.exitstatus, "the FIRST select wins the claim:\n#{first_out}"

      second_out, second_status, second_err = run.call("--json", session: SESSION_B)

      assert_equal 10, second_status.exitstatus,
        "a second pair on a task already under review is REFUSED (10):\n#{second_out}#{second_err}"
      assert_equal 1, intent_posts(requests).size,
        "ONE task, ONE review intent — the refused select recorded nothing"
      refute second_out.lines.any? { |l| l.strip.start_with?("{") && l.include?("\"reviewers\"") },
        "a refusal emits no machine-readable pick a caller could act on:\n#{second_out}"
    end
  end

  def test_the_refusal_names_the_holder_and_where_to_go_instead
    # A refusal that cannot be acted on just moves the stall. It must say WHO holds the
    # review (so the loser can ask, not seize) and name the next move.
    with_board({ "shape" => "backend", "built_by" => "shannon" }) do |run, _requests|
      run.call("--json", session: SESSION_A)
      _out, _status, err = run.call("--json", session: SESSION_B)

      assert_match(/ALREADY UNDER REVIEW/, err, "the refusal says what happened")
      assert_includes err, SESSION_A[0, 8], "and names the holding session"
      assert_match(/carl/, err, "and the soul in the seat")
      assert_match(/bin\/task claim-next-review/, err, "and where to go instead")
      assert_match(/bin\/task review-claim status/, err, "and how to check a stale lease")
    end
  end

  # --- THE EXIT-10 ARMS, AS THE CALLER READS THEM (name-both-exit-10-arms) ---------
  #
  # Two refusals share exit 10 on purpose (ReviewClaimCli::SKIPPED uses the same number),
  # so bin/pr-review cannot branch on the code — it reads the arm off the refusal's LEAD
  # PHRASE, through ReviewerSelectSkip. That is a cross-file coupling with a quiet
  # failure mode: reword a refusal here and the classifier stops recognising it.
  #
  # These two tests are the coupling's guard, and they are deliberately driven END TO
  # END — the REAL bin/reviewer-select, refused by a stub board, classified from its
  # ACTUAL stderr. A test that asserted the marker appears in this script's SOURCE could
  # be satisfied by a comment; only the live refusal proves what a caller receives.

  def test_the_held_refusal_classifies_as_the_held_arm
    with_board({ "shape" => "backend", "built_by" => "shannon" }) do |run, _requests|
      run.call("--json", session: SESSION_A)
      _out, _status, err = run.call("--json", session: SESSION_B)

      assert_equal :held, ReviewerSelectSkip.arm(err),
                   "bin/pr-review reads this refusal's lead phrase (ReviewerSelectSkip::HELD_MARKER, " \
                   "#{ReviewerSelectSkip::HELD_MARKER.inspect}) to name the arm. If refuse_held! was " \
                   "reworded, move the constant in the SAME commit — a stale marker does not raise, " \
                   "it downgrades the caller's message to the two-armed 'could not tell' text"
      assert_includes ReviewerSelectSkip.message(BOARD_SLUG, err), "bin/task claim-next-review",
                      "the held arm's remedy is to review ANOTHER task"
    end
  end

  def test_the_self_review_refusal_classifies_as_the_self_review_arm
    devops = { "shape" => "backend", "built_by" => "shannon" }
    with_board(devops, self_review: true) do |run, requests|
      out, status, err = run.call("--json", session: SESSION_A)

      assert_equal 10, status.exitstatus,
        "a self-review refusal SKIPS on the same exit code as a held one (that is the card):\n#{out}#{err}"
      assert_equal 0, intent_posts(requests).size, "a refused selection records nothing"

      assert_equal :self_review, ReviewerSelectSkip.arm(err),
                   "bin/pr-review reads this refusal's lead phrase (ReviewerSelectSkip::SELF_REVIEW_MARKER, " \
                   "#{ReviewerSelectSkip::SELF_REVIEW_MARKER.inspect}) to name the arm. If " \
                   "refuse_self_review! was reworded, move the constant in the SAME commit. A stale " \
                   "marker does not raise: it downgrades the caller's message to the two-armed " \
                   "'could not tell' text, which is honest but stops naming THIS arm — and the " \
                   "moment anyone 'simplifies' that unknown case back to a :held default, the " \
                   "original bug is live again"

      message = ReviewerSelectSkip.message(BOARD_SLUG, err)
      assert_includes message, "--actor",
                      "nobody holds this review — the remedy is to reconcile the AUTHOR SET"
      refute_includes message, "bin/task claim-next-review",
                      "and NOT to take the next task: the same refusal recurs on the next run"
    end
  end

  def test_the_same_session_selecting_twice_is_NOT_refused
    # THE BLAST-RADIUS CONTROL. The lease identity is the SESSION's — its id plus a
    # nonce anchored to the agent process every bin/ call descends from — and a reviewer
    # SUBAGENT shares it rather than having its own. So the primary's own re-select, and
    # their later `bin/task review-claim acquire`, must read as :same_instance and
    # proceed. A guard that locked a reviewer out of their own review would pass the
    # refusal test above and still wedge the entire review lane.
    with_board({ "shape" => "backend", "built_by" => "shannon" }) do |run, requests|
      _first_out, first_status, = run.call("--json", session: SESSION_A)
      second_out, second_status, second_err = run.call("--json", session: SESSION_A)

      assert_equal 0, first_status.exitstatus
      assert_equal 0, second_status.exitstatus,
        "the SAME live instance re-selecting is not a conflict:\n#{second_out}#{second_err}"
      assert_equal 2, claim_posts(requests).size, "both runs asked for the claim"
      assert json_decision(second_out)["intent_recorded"], "and the second run still records"
    end
  end

  def test_the_claim_is_acquired_BEFORE_the_intent_is_recorded
    # ORDER is the invariant, not merely "both calls happen". An intent written first
    # and a claim attempted after would leave exactly the board face this bug is about —
    # "under review" with nothing holding the task — for every run that loses the claim.
    with_board({ "shape" => "backend", "built_by" => "shannon" }) do |run, requests|
      run.call("--json", session: SESSION_A)

      posts = requests.select { |r| r[:method] == "POST" }.map { |r| r[:path] }
      claim_at = posts.index { |p| p.end_with?("/review_claim") }
      intent_at = posts.index { |p| p.end_with?("/intent") }

      refute_nil claim_at, "the default run takes the review claim: #{posts.inspect}"
      refute_nil intent_at, "and records the intent: #{posts.inspect}"
      assert claim_at < intent_at,
        "the claim must be won BEFORE the intent is announced: #{posts.inspect}"
    end
  end

  def test_no_record_reserves_nothing_just_as_it_records_nothing
    # --no-record/--dry are ADVISORY. Taking a review lease on a task the caller only
    # asked about would pin it for the full review TTL against the reviewer who
    # actually wants it — a silent denial of service dressed as a preview.
    requests, out, status = run_board({ "shape" => "backend", "built_by" => "shannon" },
                                      "--no-record", "--json")
    assert_equal 0, status.exitstatus, out
    assert_equal 0, claim_posts(requests).size, "--no-record claims nothing"
    assert_equal 0, intent_posts(requests).size, "--no-record records nothing"
  end

  def test_a_blind_pick_never_even_reserves_the_task
    # The author refusal (exit 2) fires BEFORE the claim, so a pick the tool refuses to
    # make cannot leave a lease behind either. Otherwise a run that selected nobody would
    # still lock the task out of the review lane for the TTL.
    requests, out, status = run_board({ "shape" => "backend" }, "--json")

    assert_equal 2, status.exitstatus, out
    assert_equal 0, claim_posts(requests).size, "a refused selection reserves nothing"
    assert_equal 0, intent_posts(requests).size, "and records nothing"
  end

  def test_record_flag_is_a_back_compat_synonym_for_the_default
    requests, out, status = run_board({ "shape" => "backend", "built_by" => "shannon" }, "--record", "--json")
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

  # `built_by` is named on purpose in both: PR #846 (feat/builder-stamp-misses-
  # reviewer-guard) makes an UNKNOWN builder a hard refusal (exit 2), so a run
  # that leaves it blank stops selecting the moment that lands. These tests are
  # about the BUSY read, not the builder rule — naming the builder keeps them
  # asserting the thing they are named for whichever PR merges first.
  def test_an_unreadable_busy_read_still_picks_but_announces_the_degradation
    _requests, out, status, err = run_board({ "shape" => "backend", "built_by" => "shannon" },
                                            "--busy-auto", "--json",
                                            busy_payload: "<html>502 Bad Gateway</html>",
                                            review_payload: empty_board)

    assert_equal 0, status.exitstatus, "the fail-open is intact — --busy-auto never aborts the pick"
    assert_equal 2, json_decision(out)["reviewers"].size, "a pair still forms"
    assert_includes err, "busy-auto: could not read who is mid-build"
    assert_includes err, "DEGRADED pick, not an idle bench"
  end

  def test_a_healthy_busy_read_is_silent
    # The control: the warning must fire on an unreadable answer, not on every run.
    _requests, out, status, err = run_board({ "shape" => "backend", "built_by" => "shannon" },
                                            "--busy-auto", "--json",
                                            busy_payload: empty_board, review_payload: empty_board)

    assert_equal 0, status.exitstatus, out
    refute_includes err, "busy-auto: could not read", "a genuinely idle bench raises no alarm"
  end

  # --- THE MID-REVIEW HALF (busy-auto-misses-mid-review) ------------------------
  #
  # --busy-auto read ONE half of "who is heads-down": the agents on stage=building
  # tasks. A soul mid-REVIEW is not on a building task at all — they are on a
  # SUBMITTED task holding a live TaskReviewClaim — so the flag could not have caught
  # them however well it worked. Measured 2026-09-22: the conductor overrode the pick
  # BY HAND four times in one night for exactly this, and one override spent Avi's
  # QA-owner exclusion on PR #1521.
  #
  # ONE READ, and that is the load-bearing part. The holder was always reachable per
  # task (GET /api/v1/tasks/<slug>/review_claim), so an N+1 against that endpoint
  # would pass a "does it exclude them" test while leaving the cost the card is about.
  # These assert the REQUESTS as well as the pick.

  # A submitted-stage index page, as `full=1` renders it: `review_holder` names the
  # reviewing soul, `review_claim_live` says whether anyone holds it at all.
  def review_board(*rows)
    JSON.generate("data" => rows, "meta" => { "page" => 1, "per_page" => 100,
                                              "total" => rows.size, "total_pages" => 1 })
  end

  def reviewed_row(slug, holder:, live: true)
    { "slug" => slug, "stage" => "submitted", "review_in_progress" => live,
      "review_claim_live" => live, "review_holder" => holder }
  end

  def building_board(*rows)
    JSON.generate("data" => rows, "meta" => { "page" => 1, "per_page" => 100,
                                              "total" => rows.size, "total_pages" => 1 })
  end

  def empty_board
    JSON.generate("data" => [], "meta" => { "page" => 1, "per_page" => 100,
                                            "total" => 0, "total_pages" => 1 })
  end

  def test_busy_auto_names_mid_review_souls_not_only_mid_build
    _requests, out, status, err = run_board(
      { "shape" => "backend", "built_by" => "steffon" }, "--busy-auto", "--json",
      busy_payload: building_board({ "slug" => "other-build", "agent_slug" => "shannon" }),
      review_payload: review_board(reviewed_row("other-review", holder: "jasper"))
    )

    assert_equal 0, status.exitstatus, "#{out}#{err}"
    decision = json_decision(out)

    assert_includes decision["busy"], "jasper",
      "jasper holds a LIVE review claim on another submitted task — mid-review is heads-down " \
      "exactly as mid-build is, and this half did not exist before"
    assert_includes decision["busy"], "shannon", "and the mid-build half is still read"
    refute_includes decision["candidates"], "jasper",
      "a soul mid-review must leave the LIGHT pool, which is the whole point of reading them"
  end

  # THE TRAP THIS CARD NAMES. The per-task endpoint works, so a busy set could be
  # built from it — at one round trip PER in-review task. Asserting the REQUESTS is
  # the only thing that tells the two implementations apart, because both pass the
  # test above.
  def test_the_mid_review_half_costs_one_read_not_one_per_task
    rows = (1..4).map { |i| reviewed_row("in-review-#{i}", holder: "jasper") }
    requests, out, status, = run_board(
      { "shape" => "backend", "built_by" => "steffon" }, "--busy-auto", "--json",
      busy_payload: empty_board, review_payload: review_board(*rows)
    )

    assert_equal 0, status.exitstatus, out
    per_task = requests.count { |r| r[:path].to_s.include?("/review_claim") && r[:method] == "GET" }
    index_reads = requests.count { |r| r[:path].to_s.include?("stage=submitted") }

    assert_equal 0, per_task,
      "four in-review tasks must cost ZERO per-task /review_claim reads. That endpoint WORKS, " \
      "which is the trap: an N+1 against it excludes the right souls and leaves the cost this " \
      "card exists to remove"
    assert_equal 1, index_reads, "the whole mid-review half is ONE index read"
  end

  # A soul mid-review whose claim names nobody cannot be excluded BY NAME. Scoring
  # that as an idle seat is this card's failure mode in miniature, so it is said.
  def test_a_live_claim_naming_no_soul_is_reported_rather_than_scored_idle
    _requests, _out, status, err = run_board(
      { "shape" => "backend", "built_by" => "shannon" }, "--busy-auto", "--json",
      busy_payload: empty_board,
      review_payload: review_board(reviewed_row("unnamed-review", holder: nil))
    )

    assert_equal 0, status.exitstatus
    assert_includes err, "LIVE review claim that names no soul"
    assert_includes err, "CANNOT be excluded by name"
  end

  # The two halves fail INDEPENDENTLY, so a degradation has to say WHICH one it lost:
  # a pick missing only the mid-review half is a different partial answer from one
  # missing both, and "busy-auto degraded" alone cannot tell them apart.
  def test_a_lost_half_names_itself_and_the_other_half_still_reads
    _requests, out, status, err = run_board(
      { "shape" => "backend", "built_by" => "steffon" }, "--busy-auto", "--json",
      busy_payload: building_board({ "slug" => "other-build", "agent_slug" => "shannon" }),
      review_payload: "<html>502 Bad Gateway</html>"
    )

    assert_equal 0, status.exitstatus, "a lost half never aborts the pick"
    assert_includes err, "could not read who is mid-review"
    refute_includes err, "could not read who is mid-build",
      "only the half that failed may be reported — naming both would hide which one to distrust"
    assert_includes json_decision(out)["busy"], "shannon",
      "and the half that READ must still count"
  end

  # A truncated page is a busy set silently missing whoever fell off the end — the
  # same failure wearing a different hat.
  def test_a_truncated_half_says_so
    payload = JSON.generate("data" => [reviewed_row("in-review-1", holder: "jasper")],
                            "meta" => { "page" => 1, "per_page" => 100,
                                        "total" => 140, "total_pages" => 2 })
    _requests, _out, status, err = run_board(
      { "shape" => "backend", "built_by" => "shannon" }, "--busy-auto", "--json",
      busy_payload: empty_board, review_payload: payload
    )

    assert_equal 0, status.exitstatus
    assert_includes err, "page 1 of 2"
    assert_includes err, "PARTIAL half, not an idle bench"
  end

  # --- AN EMPTY BUSY SET READS APART FROM AN IDLE BENCH ------------------------

  def test_a_bare_run_records_that_nobody_asked
    out, code = select({ "shape" => "backend", "built_by" => "shannon" }, "--json")

    assert_equal 0, code, out
    refute JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })["busy_asked"],
      "no --busy and no --busy-auto means the exclusion never RAN; a consumer that reads " \
      "`busy: []` as an idle bench is making the call that cost four hand overrides"
  end

  def test_a_busy_auto_run_records_that_somebody_asked
    _requests, out, status, = run_board({ "shape" => "backend", "built_by" => "shannon" },
                                        "--busy-auto", "--json",
                                        busy_payload: empty_board, review_payload: empty_board)

    assert_equal 0, status.exitstatus, out
    assert json_decision(out)["busy_asked"],
      "the query RAN and the bench really was idle — the opposite fact from nobody asking"
  end

  # The human audit line is where an operator actually reads this, so it is asserted
  # there too: a DISABLED safety check must read as disabled, not as a tidy blank.
  def test_the_audit_line_says_the_busy_exclusion_was_off
    out, code = select_verbose({ "shape" => "backend", "built_by" => "shannon" })

    assert_equal 0, code, out
    assert_includes out, "busy=NOT-ASKED(no-exclusion)",
      "a bare `busy=-` reads as a bench that was checked and found idle"
  end

  # --- THE AUTHOR SET, end to end through the CLI ------------------------------
  # (reviewer-select-seats-authors) devops.built_by holds ONE soul; a task can have
  # SEVERAL. On 2026-08-30 this very command seated ALEX as the light on a diff Xan
  # had written every test on, because built_by said "steffon" (PR #1081). The CLI
  # is where a human is present to choose, so it FAILS CLOSED where the in-app
  # recorder must keep degrading.

  def test_every_author_on_the_task_is_excluded_from_the_light
    out, code = select({ "shape" => "backend", "built_by" => "steffon",
                         "builders" => %w[steffon xan] }, "--json")
    assert_equal 0, code, out

    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal %w[steffon xan], decision["builders"]
    refute_includes decision["candidates"], "xan", "the co-author is out of the light pool"
    refute_includes decision["candidates"], "steffon"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "xan",
                    "THE LIVE FAILURE: xan took this seat on his own diff"
  end

  def test_human_output_names_every_author_not_just_built_by
    out, code = select("shape" => "backend", "built_by" => "steffon", "builders" => %w[steffon xan])
    assert_equal 0, code, out
    assert_match(/steffon \(author/, out)
    assert_match(/xan \(author/, out, "the co-author must appear on the excluded line too")
  end

  def test_a_legacy_unnamed_marker_no_longer_refuses
    # devops.builders_unattributed was deleted in devops-v3 4b-ii-b; a record still
    # carrying it selects on its named authors.
    out, code = select({ "shape" => "backend", "built_by" => "steffon",
                         "builders" => %w[steffon],
                         "builders_unattributed" => "sess-xan-0001" }, "--json --no-record")
    assert_equal 0, code, out
    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    refute_includes decision["candidates"], "steffon"
  end

  def test_a_kept_author_REFUSES_rather_than_taking_the_seat
    # The pool yields rather than starve, so the recorder always returns a pair. Here
    # that residue is a soul about to review their own diff: with carl the qa_owner
    # he yields the primary seat, so BOTH seats come from a light pool of four, and
    # three authors cannot all be dropped.
    out, code = select_verbose({ "shape" => "backend", "built_by" => "shannon",
                                 "builders" => %w[shannon jasper steffon xan] },
                               "--qa-owner carl --no-record")
    assert_equal 2, code, out
    assert_match(/AN AUTHOR WOULD BE SEATED/, out)
    refute_match(/^PRIMARY/, out, "no pair is printed when one seat would be an author")
  end

  # --- an unrecognised soul cannot lift the refusal ----------------------------

  def test_a_typod_builder_flag_REFUSES
    # `--builder stefon` (one f) matched the SOUL_SLUG shape, so it was a KNOWN
    # builder that excluded NOBODY — the fail-closed refusal lifted by a value
    # identifying no one.
    out, code = select_verbose({ "shape" => "backend" }, "--builder stefon --no-record")
    assert_equal 2, code, out
    assert_match(/REFUSED/, out)
    refute_match(/^PRIMARY/, out)
  end

  def test_a_PARTIAL_typo_in_the_builder_list_REFUSES
    # The sharp case: `steffon` resolves, `alexx` does not, so the set is non-empty
    # and the authors read as KNOWN — while xan, the soul the caller meant to keep
    # out, never registered. Honoring the half we understood is criterion 2's
    # fail-open wearing criterion 1's clothes.
    out, code = select_verbose({ "shape" => "backend" }, "--builder steffon,alexx --no-record")
    assert_equal 2, code, out
    assert_match(/AN AUTHOR NAMED NOBODY/, out)
    assert_match(/alexx/, out, "the refusal must name the entry that resolved to nobody")
    refute_match(/^PRIMARY/, out, "no pair is printed on a half-understood answer")
  end

  def test_a_fully_resolved_builder_list_still_selects
    out, code = select({ "shape" => "backend" }, "--builder steffon,xan --json")
    assert_equal 0, code, out
    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_empty decision["builder_override_unresolved"]
    assert_equal %w[steffon xan], decision["builders"]
  end

  def test_a_typod_built_by_on_the_record_REFUSES
    out, code = select_verbose({ "shape" => "backend", "built_by" => "shanon" }, "--no-record")
    assert_equal 2, code, out
    assert_match(/REFUSED/, out)
    # WHICH refusal, not merely that one fired. This asserted only /REFUSED/, and
    # all four refusals satisfy that — so the message calling a populated built_by
    # "blank" was invisible to the suite that covered it.
    assert_match(/shanon/, out, "the refusal must quote back the name it could not resolve")
    refute_match(/built_by is blank/, out,
                 "built_by holds \"shanon\" — reporting it as blank sends the reader to " \
                 "re-stamp the field, which OVERWRITES the typo instead of fixing it")
  end

  # THE PROPERTY, not two example strings: a blank record and a typo'd record are
  # different states, they need opposite fixes, and they must not read alike.
  def test_a_blank_record_and_a_typod_record_give_different_remedies
    blank, blank_code = select_verbose({ "shape" => "backend", "built_by" => "" }, "--no-record")
    typo,  typo_code  = select_verbose({ "shape" => "backend", "built_by" => "shanon" }, "--no-record")

    assert_equal 2, blank_code
    assert_equal 2, typo_code
    refute_equal refusal_body(blank), refusal_body(typo),
                 "one message for both states is the defect — a blank field wants a stamp, " \
                 "a typo wants a correction"
  end

  # ── EVERY FLAG A REFUSAL OFFERS MUST BE ABLE TO CLEAR IT ────────────────────
  #
  # The SEATED refusal used to offer `--qa-owner <other-soul>  # free the QA-owner
  # seat`. No value of that flag has ever cleared it — measured, `--qa-owner carl`
  # makes it strictly worse (kept authors 1 -> 2). A test that greps the message for
  # a keyword passes on a remedy that does not work, which is how this survived.
  # So: parse the flags the message actually offers, run each one, and require that
  # SOME value clears the refusal.
  FLAG_VALUES = {
    "--builder" => %w[shannon none],
    "--qa-owner" => %w[carl shannon jasper steffon xan avi mack],
    "--busy" => %w[shannon]
  }.freeze

  def test_every_flag_the_seated_refusal_offers_can_actually_clear_it
    authors = %w[shannon jasper steffon xan]
    devops = { "shape" => "backend", "built_by" => "shannon", "builders" => authors }
    out, code = select_verbose(devops, "--no-record")

    assert_equal 2, code, out
    assert_match(/AN AUTHOR WOULD BE SEATED/, out)

    offered = out.scan(%r{bin/reviewer-select \S+ (--[a-z-]+)}).flatten.uniq
    refute_empty offered, "a refusal that offers no runnable flag at all is a dead end"

    offered.each do |flag|
      values = FLAG_VALUES.fetch(flag) { flunk("refusal offers #{flag}, which this test cannot exercise") }
      cleared = values.any? do |value|
        body, status = select_verbose(devops, "--no-record", flag, value)
        status.zero? && !body.match?(/AN AUTHOR WOULD BE SEATED/)
      end

      assert cleared,
             "#{flag} is printed as the remedy for AN AUTHOR WOULD BE SEATED, but no " \
             "value of it clears the refusal. A remedy that cannot be acted on gets " \
             "routed around — and the route around here is `--builder none`, which " \
             "lifts the no-self-review guard entirely."
    end
  end

  # ── THE AUDIT LINE MAY NOT INVENT A CALLER ASSERTION ────────────────────────
  def test_the_audit_line_does_not_claim_an_assertion_nobody_made
    out, code = select({ "shape" => "backend", "built_by" => "", "builders" => ["steffon"] }, "--no-record")

    assert_equal 0, code, out
    assert_match(/steffon \(author/, out, "the author must still be excluded")
    refute_match(/ASSERTED by the caller/, out,
                 "no caller passed --builder none here; the line claimed a fact the " \
                 "operator never stated, in the same breath as listing the author")
  end

  def test_the_audit_line_still_reports_a_real_assertion
    out, code = select({ "shape" => "backend" }, "--no-record", "--builder", "none")

    assert_equal 0, code, out
    assert_match(/ASSERTED by the caller/, out,
                 "when the caller DOES assert none, the audit line must say so — " \
                 "otherwise a blank and an assertion read alike")
  end

  def test_a_real_soul_still_selects
    # The roster narrows nothing real — the guard would be useless if it refused the
    # ordinary case, because it would simply get routed around.
    out, code = select({ "shape" => "backend", "built_by" => "shannon" }, "--json")
    assert_equal 0, code, out
    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal "shannon", decision["builder"]
  end

  # --- the REVIEWER FIX-FORWARD (reviewer-zap-skips-author-stamp) --------------
  #
  # A reviewer who zaps the PR he is reviewing puts his commit in the merged diff,
  # so he is an author of it — but a zap makes no build claim, and the claim is the
  # only thing that stamped the author set. Measured on #1321 (2026-09-09): steffon
  # zapped be5579a5 while holding the light seat and this command then SEATED
  # STEFFON on a PR containing steffon's own commit.

  def test_a_recorded_fix_forward_author_is_excluded_from_the_light_seat
    out, code = select({ "shape" => "backend", "built_by" => "shannon",
                         "fix_forward" => ["steffon"] }, "--json", "--no-record")

    assert_equal 0, code, out
    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_includes decision["builders"], "steffon", "a soul who pushed to the PR is an author of it"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "steffon"
  end

  # A non-soul fix-forward entry (the legacy "unattributed" marker) no longer
  # refuses: the pick proceeds on the named authors.
  def test_a_legacy_unnamed_fix_forward_no_longer_refuses
    out, code = select({ "shape" => "backend", "built_by" => "shannon",
                         "fix_forward" => ["unattributed"] }, "--json", "--no-record")

    assert_equal 0, code, out
    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal %w[shannon], decision["builders"]
  end
end

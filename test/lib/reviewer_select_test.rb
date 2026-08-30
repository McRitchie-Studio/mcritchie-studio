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
                                            busy_payload: "<html>502 Bad Gateway</html>")

    assert_equal 0, status.exitstatus, "the fail-open is intact — --busy-auto never aborts the pick"
    assert_equal 2, json_decision(out)["reviewers"].size, "a pair still forms"
    assert_includes err, "busy-auto: could not read who is mid-build"
    assert_includes err, "DEGRADED pick, not an idle bench"
  end

  def test_a_healthy_busy_read_is_silent
    # The control: the warning must fire on an unreadable answer, not on every run.
    _requests, out, status, err = run_board({ "shape" => "backend", "built_by" => "shannon" },
                                            "--busy-auto", "--json",
                                            busy_payload: JSON.generate("data" => []))

    assert_equal 0, status.exitstatus, out
    refute_includes err, "busy-auto: could not read", "a genuinely idle bench raises no alarm"
  end

  # --- THE AUTHOR SET, end to end through the CLI ------------------------------
  # (reviewer-select-seats-authors) devops.built_by holds ONE soul; a task can have
  # SEVERAL. On 2026-08-30 this very command seated ALEX as the light on a diff Alex
  # had written every test on, because built_by said "steffon" (PR #1081). The CLI
  # is where a human is present to choose, so it FAILS CLOSED where the in-app
  # recorder must keep degrading.

  def test_every_author_on_the_task_is_excluded_from_the_light
    out, code = select({ "shape" => "backend", "built_by" => "steffon",
                         "builders" => %w[steffon alex] }, "--json")
    assert_equal 0, code, out

    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal %w[steffon alex], decision["builders"]
    refute_includes decision["candidates"], "alex", "the co-author is out of the light pool"
    refute_includes decision["candidates"], "steffon"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "alex",
                    "THE LIVE FAILURE: alex took this seat on his own diff"
  end

  def test_human_output_names_every_author_not_just_built_by
    out, code = select("shape" => "backend", "built_by" => "steffon", "builders" => %w[steffon alex])
    assert_equal 0, code, out
    assert_match(/steffon \(author/, out)
    assert_match(/alex \(author/, out, "the co-author must appear on the excluded line too")
  end

  def test_an_incomplete_author_set_REFUSES
    # A claim that named nobody while another author was on record: the set READS
    # complete (one soul, present) and is not. Exit 2, and nothing is recorded.
    out, code = select_verbose({ "shape" => "backend", "built_by" => "steffon",
                                 "builders" => %w[steffon],
                                 "builders_unattributed" => "sess-alex-0001" }, "--no-record")
    assert_equal 2, code, out
    assert_match(/REFUSED/, out)
    assert_match(/INCOMPLETE/, out, "the refusal must say WHY one name is not enough")
    assert_match(/sess-alex-0001/, out, "and name the session it could not attribute")
    refute_match(/^PRIMARY/, out, "a blind pair must never be printed")
  end

  def test_naming_every_author_lifts_the_refusal
    # The escape hatch, stated as a fact rather than smuggled through --busy (which
    # is what saved the live review, and says the wrong thing).
    out, code = select({ "shape" => "backend", "built_by" => "steffon",
                         "builders" => %w[steffon],
                         "builders_unattributed" => "sess-alex-0001" },
                       "--builder steffon,alex --json")
    assert_equal 0, code, out

    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_equal %w[steffon alex], decision["builders"]
    refute_includes decision["candidates"], "alex"
    refute_includes decision["candidates"], "steffon"
  end

  def test_a_kept_author_REFUSES_rather_than_taking_the_seat
    # The pool yields rather than starve, so the recorder always returns a pair. Here
    # that residue is a soul about to review their own diff: with carl the qa_owner
    # he yields the primary seat, so BOTH seats come from a light pool of four, and
    # three authors cannot all be dropped.
    out, code = select_verbose({ "shape" => "backend", "built_by" => "shannon",
                                 "builders" => %w[shannon jasper steffon alex] },
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
    # and the authors read as KNOWN — while alex, the soul the caller meant to keep
    # out, never registered. Honoring the half we understood is criterion 2's
    # fail-open wearing criterion 1's clothes.
    out, code = select_verbose({ "shape" => "backend" }, "--builder steffon,alexx --no-record")
    assert_equal 2, code, out
    assert_match(/AN AUTHOR NAMED NOBODY/, out)
    assert_match(/alexx/, out, "the refusal must name the entry that resolved to nobody")
    refute_match(/^PRIMARY/, out, "no pair is printed on a half-understood answer")
  end

  def test_a_fully_resolved_builder_list_still_selects
    out, code = select({ "shape" => "backend" }, "--builder steffon,alex --json")
    assert_equal 0, code, out
    decision = JSON.parse(out.lines.reverse.find { |l| l.strip.start_with?("{") })
    assert_empty decision["builder_override_unresolved"]
    assert_equal %w[steffon alex], decision["builders"]
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
    "--qa-owner" => %w[carl shannon jasper steffon alex avi mack],
    "--busy" => %w[shannon]
  }.freeze

  def test_every_flag_the_seated_refusal_offers_can_actually_clear_it
    authors = %w[shannon jasper steffon alex]
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
end

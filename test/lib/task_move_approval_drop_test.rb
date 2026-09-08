# frozen_string_literal: true

# [integration] `bin/task move` must announce a discarded operator-approval request
# EXACTLY when this move discarded one — and stay quiet otherwise.
#
# A move out of the request stages SETTLES a pending request
# (Task#settle_operator_approval_past_submit). That is deliberate: past `submitted`
# the PR review flow owns the work. But on 2026-09-07 it happened in SILENCE — an
# agent set --approval waiting at `building`, read it back as "waiting", ran
# bin/ship, and the handoff move discarded the request with nothing printed. The
# board never pulsed and Mr. McRitchie was never asked. The move still succeeds; it
# just has to SAY SO.
#
# THE DEFECT THIS FILE CLOSES. The first cut of that warning asked a CLOCK — is the
# drop receipt younger than `since - 300s`? — which is not the question a warning
# about THIS MOVE can answer. Measured against the real binary with a 60-second-old
# stamp, `bin/task move <slug> building` announced a discarded request on a move INTO
# a stage where a request is ACTIONABLE, and a re-run `move <slug> submitted` (the
# documented killed-ship resume) announced one drop twice. The pinning test used a
# 3600s stamp, so the boundary that decides every real case went unprobed and the
# defect shipped green. Every case below that must stay QUIET seeds a stamp ~60
# SECONDS old: each fires under the clock rule and must not fire under the effect rule.
#
# It lives in its own file rather than at the bottom of test/lib/task_cli_test.rb
# because that file is a frozen APPEND hotspot (config/test_health.yml) — adding here
# is what the ratchet asks for.
#
#   ruby -Itest test/lib/task_move_approval_drop_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"
# Neutralizes the ambient session vars and pins the usage/marker write roots, so a
# child never reads the operator's live session or writes into his real cost store.
require_relative "../support/session_env"

class TaskMoveApprovalDropTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "demo-slug"
  # The stages a request may LIVE in — the stub board's copy of
  # Task::APPROVAL_REQUEST_STAGES. A save landing anywhere else settles a waiting
  # request. Pinned against the real constant by
  # test/models/task_approval_request_guard_test.rb, which runs in a lane that HAS
  # Rails; this file is deliberately standalone and never boots the app.
  SETTLE_EXEMPT_STAGES = %w[designed building].freeze
  # ~60s: comfortably inside the retired 300s grace window, so every "must stay
  # quiet" case below is one the clock rule got wrong.
  def recent_drop = (Time.now.utc - 60).iso8601

  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("task-move-approval-sandbox")
  end

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # Shells out to the REAL bin/task against a localhost stub board. No Rails, no
  # network — the point is to drive the binary an agent actually runs.
  def run_task(args, stub_stage: "building", stub_devops: { "kind" => "feature" },
               fail_get: nil, stub_stamps_drop_receipt: true, stub_devops_after: nil)
    @stub_devops = stub_devops
    @persisted_stage = stub_stage
    @fail_get = fail_get
    # Whether the modelled settle writes the approval_request_dropped_at RECEIPT.
    # False models a board too old to carry it — which still settles the request,
    # and is the only way to exercise the warning's pre-state half on its own.
    @stub_stamps_drop_receipt = stub_stamps_drop_receipt
    # Devops served AFTER a stage PATCH lands, replacing what the pre-PATCH GET
    # showed. Models a writer that changed the record inside this move's own window,
    # which the pre-read by construction could not predict.
    @stub_devops_after = stub_devops_after

    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(sandbox_root)))

    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests)
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

      status, payload = response_for(method, path, body)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path, body)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"

    if method == "POST" && path =~ %r{\A/api/v1/sessions/.+/mascot\z}
      return ["200 OK", JSON.generate("data" => { "mascot" => "snorlax", "app" => "mcritchie-studio" })]
    end
    return ["200 OK", JSON.generate("data" => {})] if method == "GET" && path =~ %r{\A/api/v1/agents/[^/]+\z}

    if @fail_get && method == "GET" && path.start_with?("/api/v1/tasks/")
      return ["#{@fail_get} Service Unavailable", JSON.generate("error" => "stubbed board read failure")]
    end

    if method == "PATCH" && path =~ %r{\A/api/v1/tasks/[^/]+\z}
      requested = stage_of(body)
      if requested
        @persisted_stage = requested
        settle_approval_request!(requested)
      end
      return ["200 OK", task_response]
    end

    return ["200 OK", JSON.generate("data" => [])] if method == "GET" && path =~ %r{\A/api/v1/tasks(\?.*)?\z}

    if method == "GET" && path =~ %r{\A/api/v1/activities(\?.*)?\z}
      return ["200 OK", JSON.generate("data" => [],
                                      "meta" => { "page" => 1, "per_page" => 100, "total" => 0, "total_pages" => 1 })]
    end

    ["200 OK", task_response]
  end

  # The board's settle rule, MODELLED: Task#settle_operator_approval_past_submit
  # resolves a WAITING request to "none" on any save landing outside
  # APPROVAL_REQUEST_STAGES, and stamps approval_request_dropped_at as the receipt.
  #
  # A STATIC stub — the same devops hash answering the pre-PATCH GET and the PATCH —
  # is what let the defect ship: no test could tell a drop this move caused from a
  # stamp already sitting on the record. A stub that cannot express the defect
  # certifies nothing.
  def settle_approval_request!(stage)
    settle_the_waiting_request!(stage)
    # Applied LAST so it can model a record that moved underneath the pre-PATCH read.
    @stub_devops = @stub_devops_after if @stub_devops_after
  end

  def settle_the_waiting_request!(stage)
    return if SETTLE_EXEMPT_STAGES.include?(stage)
    return unless @stub_devops["approval_status"] == "waiting"

    @stub_devops = @stub_devops.merge("approval_status" => "none")
    return unless @stub_stamps_drop_receipt

    @stub_devops["approval_request_dropped_at"] = Time.now.utc.iso8601
  end

  def stage_of(body)
    return nil if body.to_s.empty?

    JSON.parse(body)["stage"]
  rescue JSON::ParserError
    nil
  end

  def task_response
    JSON.generate("data" => { "slug" => SLUG, "stage" => @persisted_stage, "merged" => "",
                              "release_slug" => nil, "metadata" => { "devops" => @stub_devops } })
  end

  def task_gets(requests)
    requests.count { |r| r[:method] == "GET" && r[:path] == "/api/v1/tasks/#{SLUG}" }
  end

  # SHAPE 1 — a move INTO a stage that can hold a request. The settle provably never
  # runs, so nothing was discarded and there is nothing to announce. The clock rule
  # announced one anyway, in a message that contradicted itself: it named `building`
  # as a stage where a request is actionable while warning about the move into it.
  def test_move_into_building_is_quiet_about_a_recent_drop
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} building],
      stub_stage: "submitted",
      stub_devops: { "kind" => "feature", "approval_status" => "none",
                     "approval_request_dropped_at" => recent_drop }
    )

    assert status.success?
    refute_match(/DISCARDED/, err,
                 "a move INTO building settles nothing — announcing a drop there is false twice over")
  end

  def test_move_into_designed_is_quiet_about_a_recent_drop
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} designed],
      stub_stage: "submitted",
      stub_devops: { "kind" => "feature", "approval_status" => "none",
                     "approval_request_dropped_at" => recent_drop }
    )

    assert status.success?
    refute_match(/DISCARDED/, err, "designed can hold a request too")
  end

  # The sharpest version of shape 1, and the one that would hurt most: the request is
  # STILL LIVE. `bin/task begin <slug> --steal` and a rework resume both move an
  # already-`building` task to `building` again, so the pre-state legitimately reads
  # "waiting" and the settle still never runs. Announcing a discarded request here
  # would tell the agent it destroyed the very request pulsing on the board right now.
  # Nothing but the destination-stage test prevents that — the pre-state half, asked
  # on its own, says "waiting, so this will be settled".
  def test_a_move_into_building_never_announces_a_request_that_is_still_live
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} building],
      stub_stage: "building",
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" }
    )

    assert status.success?
    refute_match(/DISCARDED/, err,
                 "the request survives a move into building — not discarded, still waiting")
  end

  def test_a_move_into_designed_never_announces_a_request_that_is_still_live
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} designed],
      stub_stage: "building",
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" }
    )

    assert status.success?
    refute_match(/DISCARDED/, err, "designed holds a live request too")
  end

  # ...and it does not even spend a READ to find that out. The pre-PATCH GET exists
  # only to date a possible drop, so a destination that cannot drop one must not pay
  # for it. Asserted as a DIFFERENCE between destinations rather than an absolute
  # count, so unrelated reads elsewhere in the move cannot make it lie.
  def test_a_destination_that_can_hold_a_request_spends_no_extra_read
    quiet, = run_task(%W[move #{SLUG} building], stub_stage: "submitted")
    loud,  = run_task(%W[move #{SLUG} submitted], stub_stage: "building")

    assert_equal task_gets(quiet) + 1, task_gets(loud),
                 "the pre-move read is spent only where a drop is possible"
  end

  # SHAPE 2 — a move PAST the seam that genuinely discards a pending request. The
  # case the warning exists for; it must never go quiet.
  def test_move_past_the_seam_warns_when_it_discards_a_pending_request
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} submitted],
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" }
    )

    assert status.success?, "the move itself still succeeds — the drop is a warning, not a refusal"
    assert_match(/DISCARDED a pending operator-approval request/, err,
                 "a silently dropped operator request is the whole defect")
  end

  # One drop, one line. The clock rule re-announced the same stamp on every later
  # move, and a warning that cries wolf is read as noise by the third repetition.
  def test_a_single_drop_is_announced_exactly_once
    _reqs, _out, err, _status = run_task(
      %W[move #{SLUG} submitted],
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" }
    )

    assert_equal 1, err.scan(/DISCARDED a pending operator-approval request/).size
  end

  # The message has to be actionable from where the reader STANDS: the governing
  # condition first (a decision the operator already gave), then the moves that get
  # his eyes back — not advice for last time.
  #
  # And every command it prints is RUN here, not merely matched. The first draft of
  # this rewrite advertised `bin/task move <slug> building --approval waiting`; `move`
  # has no `--approval` flag, so the one command a stuck reader would paste dies on
  # unknown_flag!. `assert_match(/--approval/, err)` passes on that. Executing it does
  # not. This is a warning whose whole job is to un-stick a reader, so advice that
  # does not run is the same defect in a new place.
  def test_every_command_the_warning_prints_actually_runs
    _reqs, _out, err, _status = run_task(
      %W[move #{SLUG} submitted],
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" }
    )

    assert_match(/already approved in words, record it/, err,
                 "the governing condition leads — not advice for last time")

    commands = err.scan(%r{bin/task ([^.,\n]+)}).flatten.map(&:split)
    # Guard the SCAN before trusting it: a regex that matched nothing would loop zero
    # times and pass silently, certifying a message it never read.
    assert_equal 3, commands.size,
                 "expected 3 runnable commands, got #{commands.inspect} from: #{err}"

    commands.each do |argv|
      _r, _o, cmd_err, cmd_status = run_task(argv)
      assert cmd_status.success?,
             "the warning tells the reader to run `bin/task #{argv.join(" ")}`, " \
             "which the CLI itself rejects: #{cmd_err}"
    end
  end

  # SHAPE 3 — the SAME move run twice. `bin/ship` is documented as resumable and a
  # killed ship is re-run routinely, so a second `move <slug> submitted` is normal.
  # The request was already settled by the first run: this move discarded nothing and
  # must say nothing. The stamp is 60s old, so the clock rule warned again here about
  # one single drop.
  def test_rerunning_the_move_does_not_warn_again_about_one_drop
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} submitted],
      stub_stage: "submitted",
      stub_devops: { "kind" => "feature", "approval_status" => "none",
                     "approval_request_dropped_at" => recent_drop }
    )

    assert status.success?
    refute_match(/DISCARDED/, err, "one drop is one warning, not one per later move")
  end

  # --- the two halves, each on its own ---
  #
  # The verdict OR-s a PRE-STATE prediction with an observation that the RECEIPT
  # moved. OR-ed guards mask each other under mutation — a case tripping both stays
  # green when either is broken — so each half gets a case that trips ONLY it. They
  # are OR-ed to fail SAFE: each covers the other's blind spot, and the union can only
  # warn MORE than either half alone, never less.

  # HALF 1 alone: a board too old to carry the receipt still SETTLES the request.
  # Nothing stamps, so the receipt cannot move and only the pre-state knows.
  def test_a_board_that_writes_no_receipt_is_still_announced
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} submitted],
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" },
      stub_stamps_drop_receipt: false
    )

    assert status.success?
    assert_match(/DISCARDED/, err,
                 "the drop is real whether or not the board is new enough to record it")
  end

  # HALF 2 alone: the pre-read said "none", so nothing predicted a drop — but the
  # receipt moved across the PATCH. Models a writer that set "waiting" inside this
  # move's own window, and the same-second collision where two stamps render alike.
  def test_a_drop_the_pre_read_could_not_predict_is_still_announced
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} submitted],
      stub_devops: { "kind" => "feature", "approval_status" => "none",
                     "approval_request_dropped_at" => (Time.now.utc - 900).iso8601 },
      stub_devops_after: { "kind" => "feature", "approval_status" => "none",
                           "approval_request_dropped_at" => Time.now.utc.iso8601 }
    )

    assert status.success?
    assert_match(/DISCARDED/, err, "a receipt that moved across this PATCH is this move's news")
  end

  # An UNREADABLE pre-state must not buy silence. Trading a false warning for a missed
  # one would re-open the exact hole the warning was built to close.
  def test_an_unreadable_pre_state_warns_rather_than_going_quiet
    _reqs, _out, err, status = run_task(
      %W[move #{SLUG} submitted],
      stub_devops: { "kind" => "feature", "approval_status" => "waiting" },
      fail_get: 503
    )

    assert status.success?, "an unreadable board does not fail the move"
    assert_match(/DISCARDED/, err, "unknown must resolve to loud, never to quiet")
  end

  def test_move_without_any_approval_request_warns_nothing
    _reqs, _out, err, status = run_task(%W[move #{SLUG} submitted])

    assert status.success?
    refute_match(/DISCARDED/, err)
  end
end

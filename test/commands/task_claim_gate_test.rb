require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"
require_relative "../support/fake_desk"

# The build-claim gate REFUSES. It does not warn and carry on.
#
# THE DESK IS THE BUILD CLAIM (bin/lib/desk_claim.rb). The gate refuses in ONE case:
# a DIFFERENT live session's desk is bound to the task AND has uncommitted changes.
# `--steal` is the override for that case. Every other case claims freely.
#
# THE ASSERTION THAT SEPARATES "REFUSES" FROM "WARNS" IS "NO WRITE". A gate that
# warns and proceeds also prints the desk and the --steal hint — every message
# assertion below would pass on it. The only thing it does that a refusing gate
# never does is send the PATCH. So the refusal is pinned on the absence of the board
# write, and the messages are pinned separately.
class TaskClaimGateTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze

  HOLDER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b".freeze
  MOVER_SESSION  = "019f4c1d-7b2e-74a2-8f19-2c7d90ab3311".freeze

  # The wording this file exists to keep buried, kept verbatim so the guard below
  # can be run against it. A guard that has never been shown to fail on the real
  # regression is a guard nobody has tested.
  HISTORICAL_HEADER = <<~TEXT
    # Refuse a move-to-building when the task is already claimed by a DIFFERENT,
    # still-live instance — unless --steal. Unclaimed / expired / corrupt /
    # same-instance claim freely. Loud (not a hard block): it prints WHO holds it +
    # how to override.
  TEXT

  CLAIM_LEASE = Rails.root.join("lib/claim_lease.rb")

  # The sibling copy, verbatim, for the same reason.
  HISTORICAL_LEGEND =
    "  #   :held_by_other — held by a DIFFERENT, still-live instance → the gate warns/refuses\n".freeze

  # ── THE REFUSAL ─────────────────────────────────────────────────────────────

  test "[integration] a move onto a foreign live desk with uncommitted work exits 1" do
    result = move_with_desk(dirty: true)

    assert_equal 1, result[:status].exitstatus, "the gate ends in `exit 1`"
  end

  # THE LOAD-BEARING ONE. Everything else here is also true of a gate that only warns.
  test "[integration] the refused move sends NO write to the board" do
    result = move_with_desk(dirty: true)

    assert_empty result[:writes],
                 "the gate refused and must have stopped there — a PATCH on this path " \
                 "means it warned and carried on over another session's uncommitted work"
  end

  test "[integration] the refusal names the desk and the override" do
    result = move_with_desk(dirty: true)

    assert_includes result[:err], result[:desk], "it must name WHERE the work at risk is"
    assert_includes result[:err], "uncommitted changes", "and why that desk blocks the claim"
    assert_includes result[:err], "#{SLUG} building --steal",
                    "a refusal with no way forward is a dead end; the override must be pasteable"
  end

  # THE OTHER SIDE OF THE SAME CONTRACT. A test that only proved the refusal would
  # pass just as well against a gate that refuses unconditionally.
  test "[integration] --steal claims over the foreign desk and writes" do
    result = move_with_desk("--steal", dirty: true)

    assert_equal 0, result[:status].exitstatus, "--steal must let the move through"
    assert_match(/--steal: claiming #{SLUG} over 1 foreign desk/, result[:err],
                 "the override names the desk it is claiming over")
    assert_equal MOVER_SESSION, result[:writes].last&.dig("event", "session")
  end

  # ONLY UNCOMMITTED WORK REFUSES. A clean foreign desk has nothing to lose.
  test "[integration] a clean foreign desk does not refuse" do
    result = move_with_desk(dirty: false)

    assert_equal 0, result[:status].exitstatus, "a clean desk holds no work at risk:\n#{result[:err]}"
    refute_empty result[:writes]
  end

  # AND THE GATE MUST NOT FIRE ON ITS OWN DESK.
  test "[integration] the desk's own session is not refused" do
    result = move_with_desk(dirty: true, holder: MOVER_SESSION)

    assert_equal 0, result[:status].exitstatus, "a builder re-claiming from its own dirty desk:\n#{result[:err]}"
    refute_empty result[:writes]
  end

  # A spawned builder's desk names its focus session as the parent: one party.
  test "[integration] the parent session of a desk is not refused" do
    result = move_with_desk(dirty: true, holder: HOLDER_SESSION, parent: MOVER_SESSION)

    assert_equal 0, result[:status].exitstatus, result[:err]
  end

  # A desk whose holder is gone (dead anchor) is nobody's.
  test "[integration] a desk whose holder is gone does not refuse" do
    result = move_with_desk(dirty: true, anchor_pid: 999_999_9)

    assert_equal 0, result[:status].exitstatus, result[:err]
  end

  # ── THE COMMENT MUST NAME WHAT THE CODE DOES ────────────────────────────────
  #
  # THE EXIT CODE IS DERIVED FROM THE FUNCTION, never restated here. That is what
  # makes this a guard rather than a second copy of the same claim: change the
  # gate to `exit 2` and this reddens until the header catches up; delete the
  # `exit` altogether and it reddens with a different message. A hand-written
  # "must say exit 1" would go on passing against a gate that no longer exits.

  test "[unit] the gate's header names the exit code the gate actually uses" do
    source = File.read(BIN)

    assert header_names_exit_code?(source),
           "bin/task's comment above enforce_claim_gate! must state that it exits " \
           "#{gate_exit_code(source)}. Prose has no other way to fail, and the last time it " \
           "drifted it taught two files that the gate warns and proceeds."
  end

  # THE GUARD, RUN AGAINST THE REAL REGRESSION. Without this the test above is a
  # green light of unknown value — it would pass identically if `header_names_exit_code?`
  # always returned true.
  test "[unit] the historical wording does not satisfy that guard" do
    source = with_historical_header(File.read(BIN))

    # PROVE THE MUTATION APPLIED. A sub that silently matched nothing would leave
    # the real header standing and this test would pass while exercising nothing.
    assert_includes source, "Loud (not a hard block)",
                     "the mutation must actually restore the old wording, or it says nothing"

    refute header_names_exit_code?(source),
           "the wording that caused this bug must FAIL the guard that exists to prevent it"
  end

  # ── THE SIBLING COPY, IN THE SHARED MODULE ──────────────────────────────────
  #
  # THE SAME DEFECT LIVED IN A SECOND FILE, one word wide. ClaimLease's
  # disposition legend read ":held_by_other … → the gate warns/refuses". Seven
  # consumers read that disposition — bin/task's build gate, bin/ship's ownership
  # guard, bin/task's heartbeat renewal, and the four claim models — and NOT ONE
  # of them warns and proceeds. "warns" named a branch that has never existed.
  #
  # So the guard is that the word is ABSENT, not that some better phrasing is
  # present: there is no consumer it could truthfully describe, and a legend that
  # offers it as an alternative is how the reading survives a reword.
  test "[unit] the disposition legend says only that :held_by_other refuses" do
    assert legend_only_refuses?(legend_entry(CLAIM_LEASE.read)),
           "ClaimLease's :held_by_other legend must say the disposition is REFUSED and must not " \
           "offer 'warn' as a reading — no consumer implements one"
  end

  test "[unit] the historical legend does not satisfy that guard" do
    assert_includes HISTORICAL_LEGEND, "warns/refuses",
                    "the fixture must be the wording that caused the bug, or it proves nothing"

    refute legend_only_refuses?(HISTORICAL_LEGEND),
           "the legend that taught two files the wrong contract must FAIL this guard"
  end

  private

  # ── THE GUARD, AS A FUNCTION OF SOURCE ──────────────────────────────────────
  # Taking SOURCE rather than reading BIN lets the mutation test run the REAL
  # check against a deliberately-reverted copy of the real file, instead of
  # against a hand-written fake that could only confirm what its author believed.
  def header_names_exit_code?(source)
    gate_header(source).include?("exit #{gate_exit_code(source)}")
  end

  # The contiguous comment block immediately above the definition.
  def gate_header(source)
    source[/((?:^#.*\n)+)(?=^def enforce_claim_gate!)/, 1] ||
      flunk("no comment block above enforce_claim_gate! — the header this guard reads is gone")
  end

  # The exit code the gate's refusal path uses, read out of the function body.
  def gate_exit_code(source)
    body = source[/^def enforce_claim_gate!.*?^end$/m] ||
           flunk("could not isolate enforce_claim_gate! in bin/task")
    body[/^\s*exit (\d+)\s*$/, 1] ||
      flunk("enforce_claim_gate! no longer exits — the refusal this guards is gone, so fix " \
            "the gate or delete this guard deliberately; do not loosen it")
  end

  def with_historical_header(source)
    source.sub(gate_header(source), HISTORICAL_HEADER)
  end

  # The :held_by_other entry of ClaimLease's disposition legend — its own line
  # plus the indented continuations, up to the blank comment line that ends the
  # legend.
  def legend_entry(source)
    source[/^\s*#\s+:held_by_other —.*?(?=^\s*#\s*$)/m] ||
      flunk("could not find the :held_by_other entry in ClaimLease's disposition legend")
  end

  def legend_only_refuses?(text)
    text.match?(/refuse/i) && !text.match?(/warn/i)
  end

  # ── DRIVING THE REAL BINARY ─────────────────────────────────────────────────

  # Run `bin/task move <slug> building` against a stub board, with ONE desk bound to
  # SLUG under the child's projects root. Returns the exit status, stderr, every
  # PATCH body the CLI sent, and the desk path.
  def move_with_desk(*flags, dirty:, holder: HOLDER_SESSION, parent: nil, anchor_pid: nil)
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => MOVER_SESSION
        )
      )
      desk = FakeDesk.build(File.join(dir, "projects"), task_slug: SLUG, session: holder,
                                                          dirty: dirty, parent: parent)
      if anchor_pid
        ctx = File.join(desk, ".agent-context.json")
        File.write(ctx, JSON.generate(JSON.parse(File.read(ctx)).merge("anchor_pid" => anchor_pid)))
      end

      with_board_sink(writes) do |base|
        _out, err, status = Open3.capture3(env.merge("TASK_API_BASE" => base),
                                           BIN, "move", SLUG, "building", *flags)
      end

      { status: status, err: err, desk: desk,
        writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  # A board answering the calls `move` makes: the bearer exchange (POST /auth), the
  # task read, and — only if the gate lets it through — the PATCH. ONLY PATCH BODIES
  # ARE RECORDED: the auth POST happens on every run, so counting it would make the
  # "no write" assertion unfalsifiable.
  def with_board_sink(writes)
    server = TCPServer.new("127.0.0.1", 0)
    auth = { token: "sink-bearer" }.to_json
    task = task_body
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        writes << payload if payload && request.start_with?("PATCH")
        body = request.include?("/api/v1/auth") ? auth : task
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill
  end

  # Already `building`, so the post-PATCH read-back verify agrees.
  def task_body
    { data: { slug: SLUG, stage: "building", title: "Probe Task",
              metadata: { devops: { kind: "bug", repositories: ["mcritchie-studio"], worktree_slug: SLUG } } } }.to_json
  end
end

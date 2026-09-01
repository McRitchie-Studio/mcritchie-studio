require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"

# The build-claim gate REFUSES. It does not warn and carry on.
#
# THE DEFECT THIS EXISTS TO CATCH is a comment, not a branch — and that is
# exactly why it needed a test. `bin/task`'s header above `enforce_claim_gate!`
# read "Loud (not a hard block): it prints WHO holds it + how to override." The
# author meant "overridable by --steal". It READ as warns-and-proceeds, and a
# reader carried that reading into docs/agents/modules/worktrees.md as "warns and
# proceeds — it is loud, not blocking", which would have had the next agent
# pre-arm --steal against a live builder's desk: the exact fail-open the gate
# exists to close. That doc was corrected first and reads "refuses — exit 1"
# today; `lib/claim_lease.rb`'s disposition legend carried the same error one
# word wide ("the gate warns/refuses") and is corrected here.
#
# The code was never wrong. `enforce_claim_gate!` has ended in `exit 1` the whole
# time, and nothing in the tree exercised that fact, so the prose was free to
# drift away from it in two files without a single test going red.
#
# THE ASSERTION THAT SEPARATES THE TWO READINGS IS "NO WRITE". A gate that warns
# and proceeds also prints the holder, the heartbeat age, and the --steal hint —
# every message assertion below would pass on it. The only thing it does that a
# refusing gate never does is send the PATCH. So the refusal is pinned on the
# absence of the board write, and the messages are pinned separately as the
# evidence the operator decides `--steal` on.
class TaskClaimGateTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze

  # Two distinct live instances. The nonce is injected through TASK_CLAIM_NONCE
  # (SessionIdentity's documented test seam) so the identity under test is data
  # rather than whatever process tree the suite happens to run under.
  HOLDER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b".freeze
  HOLDER_NONCE   = "holder01".freeze
  MOVER_SESSION  = "019f4c1d-7b2e-74a2-8f19-2c7d90ab3311".freeze
  MOVER_NONCE    = "mover001".freeze

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

  test "[integration] a move onto a live foreign claim exits 1" do
    result = move_against_foreign_claim

    assert_equal 1, result[:status].exitstatus,
                 "the gate ends in `exit 1`; a warns-and-proceeds gate would exit 0 " \
                 "and the prose that described it as one would be right"
  end

  # THE LOAD-BEARING ONE. Everything else here is also true of a gate that only
  # warns; this is not.
  test "[integration] the refused move sends NO write to the board" do
    result = move_against_foreign_claim

    assert_empty result[:writes],
                 "the gate refused and must have stopped there — a PATCH on this path " \
                 "means it warned and carried on, claiming another live instance's task"
  end

  test "[integration] the refusal names the holder, its heartbeat, and the override" do
    err = move_against_foreign_claim[:err]

    assert_includes err, "claimed by a DIFFERENT live instance",
                     "the refusal must say what it is refusing on"
    assert_includes err, HOLDER_SESSION[-4..],
                     "it must name WHO holds it — the operator cannot weigh --steal otherwise"
    assert_includes err, "last heartbeat",
                     "and how stale that holder's liveness signal is"
    assert_includes err, "bin/task move #{SLUG} building --steal",
                     "a refusal with no way forward is a dead end; the override must be pasteable"
  end

  # THE OTHER SIDE OF THE SAME CONTRACT. `--steal` is the ONLY way past the gate,
  # so a test that only proved the refusal would pass just as well against a gate
  # that refuses unconditionally — which would wedge every legitimate takeover.
  test "[integration] --steal takes the claim over and writes" do
    result = move_against_foreign_claim("--steal")

    assert_equal 0, result[:status].exitstatus, "--steal must let the move through"
    claim = result[:writes].last&.dig("devops") || {}
    assert_equal MOVER_SESSION, claim["claimed_session"],
                 "the takeover must durably TRANSFER the lease to the stealing instance, " \
                 "not merely skip the check and leave the holder on the record"
  end

  # AND THE GATE MUST NOT FIRE ON ITS OWN HOLDER. Session AND nonce match, so this
  # is :same_instance — the ordinary re-move a builder does all day.
  test "[integration] the holder's own re-move is not refused" do
    result = move_against_foreign_claim(session: HOLDER_SESSION, nonce: HOLDER_NONCE)

    assert_equal 0, result[:status].exitstatus,
                 "a gate that refused the holder's own instance would block every legitimate " \
                 "re-claim; :same_instance claims freely"
    refute_empty result[:writes], "and the claim renewal must still land"
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

  # Run `bin/task move <slug> building` against a board holding a LIVE claim from
  # HOLDER_SESSION, and return the exit status, stderr, and every write the CLI
  # sent. The mover defaults to a different live instance (:held_by_other).
  # The child env goes through BOTH sandboxes on purpose. SessionEnv.neutralized
  # scrubs the operator's ambient session before opting this run in to a fake one,
  # and TaskUsageSandboxEnv.child_env pins the usage store, the transcript root,
  # and HOME inside a tmpdir. Skipping the second is not a style lapse: the suite
  # arms TASK_USAGE_SANDBOX process-wide, so an unpinned child ABORTS before it
  # reaches the gate — and the first draft of this file did exactly that. Two
  # tests passed anyway, on an exit 1 and an empty write log produced by a
  # completely different refusal. The message assertions are what caught it.
  def move_against_foreign_claim(*flags, session: MOVER_SESSION, nonce: MOVER_NONCE)
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => session, "TASK_CLAIM_NONCE" => nonce
        )
      )

      with_board_sink(writes) do |base|
        _out, err, status = Open3.capture3(env.merge("TASK_API_BASE" => base),
                                           BIN, "move", SLUG, "building", *flags)
      end

      { status: status, err: err, writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  # A board answering the calls `move` makes: the bearer exchange (POST /auth),
  # the task read the gate judges, and — only if the gate lets it through — the
  # PATCH. ROUTING BY PATH MATTERS: a sink returning one body for every request
  # answers /auth with a task and bin/task dies on a missing "token".
  #
  # ONLY PATCH BODIES ARE RECORDED. The auth POST happens on every run, refused
  # or not, so counting it would make the "no write" assertion unfalsifiable.
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

  # The task as the board serves it: already `building` (so the post-PATCH
  # read-back verify agrees on the runs that get that far) and carrying a lease
  # HOLDER_SESSION renewed moments ago. 90s of headroom on a 120s TTL keeps it
  # unambiguously live without pinning the test to the suite's wall clock.
  def task_body
    { data: { slug: SLUG, stage: "building", title: "Probe Task",
              metadata: { devops: {
                kind: "bug", repositories: ["mcritchie-studio"],
                worktree_slug: SLUG,
                claimed_session: HOLDER_SESSION,
                claim_nonce: HOLDER_NONCE,
                claim_expires_at: (Time.now + 90).utc.iso8601
              } } } }.to_json
  end
end

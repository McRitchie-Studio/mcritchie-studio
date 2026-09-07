# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"
require_relative "../support/session_env"

# ONLY THE VERDICT OWNER MAY SPEND THE BOUNCE.
#
# ═══ THE INCIDENT (2026-09-07, turf-monster PR 594) ═══
#
# A pr-review primary (Carl) held the review claim on `interpreter-names-wrong-modal`
# and summoned a domain LIGHT (alex) per carl/sops/pr-review-light.md. The light ran
#
#     bin/task block <slug> --kind rework
#
# on its own initiative, then reported back to its Carl as though it had only filed a
# scout report — its report closed with "Your call as owner." while the block was
# ALREADY on the board.
#
# The two-bounce circuit breaker is a SCARCE, TASK-SCOPED resource. The light spent
# the task's ONE bounce, so when the OWNING Carl composed his own block minutes later
# `bin/task block` REFUSED him (bounces exit 10, TRIPPED). The owner was locked out of
# his own verdict by his own assistant, and the block cleared the review claim
# mid-review. A task can reach escalation without a primary ever having blocked it.
#
# THE GAP IS ENFORCEMENT, NOT DOCUMENTATION. pr-review-light.md already says the light
# does not drive the verdict, and this light was additionally briefed in its prompt
# with the prohibition spelled out. Prose did not hold.
#
# ═══ WHY THE OBVIOUS FIX IS INERT — the fixture below is built on this ═══
#
# The ticket proposed requiring that the caller HOLD THE REVIEW LEASE. That check
# cannot see this bug, and the fixture is shaped to prove it rather than to assert it.
#
# A lease identifies a LIVE INSTANCE: SessionIdentity = CLAUDE_CODE_SESSION_ID + a
# nonce anchored to the `claude` CLI PROCESS (bin/lib/session_identity.rb). A light is
# a SUBAGENT of its primary's session — same session id, same `claude` ancestor
# process, therefore the SAME NONCE. Measured 2026-09-07 by reading both out of a live
# subagent. So ClaimLease.evaluate would grade the light `:same_instance` and wave it
# straight through, and a gate written on the lease would have been green on the exact
# incident that motivated it.
#
# Hence LIGHT_SESSION == HOLDER_SESSION and LIGHT_NONCE == HOLDER_NONCE below. The
# ONLY thing that separates the light from its primary is the SOUL — and the review
# claim has recorded one (`holder_agent`, published as holder["agent"]) since the crew
# seat rode the claim. That is the axis this gate is built on.
#
# ═══ THE LOAD-BEARING ASSERTION IS "NO WRITE" ═══
#
# A gate that WARNS and carries on prints the same holder, the same soul, and the same
# remedy — every message assertion here would pass against it. The one thing it does
# that a refusing gate never does is send the PATCH and the qa_feedback POST. So the
# refusal is pinned on the ABSENCE of those writes, and the messages are pinned
# separately as the evidence the reader acts on.
class BlockVerdictOwnerGateTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "probe-review"

  # ONE live instance, shared by the primary and its light — see the header. A
  # lease-identity check grades this `:same_instance`; the souls differ.
  HOLDER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b"
  HOLDER_NONCE   = "holder01"
  LIGHT_SESSION  = HOLDER_SESSION
  LIGHT_NONCE    = HOLDER_NONCE

  PRIMARY = "carl"
  LIGHT   = "alex"

  # ── THE REFUSAL ─────────────────────────────────────────────────────────────

  def test_integration_a_light_rework_block_under_a_foreign_review_is_refused
    result = block_as(LIGHT)

    refute_equal 0, result[:status].exitstatus,
                 "a light does not hold the verdict, so its rework block must REFUSE — " \
                 "exit 0 here is the incident reproducing"
  end

  # THE ONE THAT SEPARATES A REFUSAL FROM A WARNING.
  def test_integration_the_refused_block_sends_no_write_to_the_board
    result = block_as(LIGHT)

    assert_empty result[:writes],
                 "the gate refused and must have stopped there — a PATCH /block or a " \
                 "qa_feedback POST on this path means the light SPENT THE BOUNCE, which " \
                 "is the whole defect"
  end

  def test_integration_the_refusal_names_the_owner_the_caller_and_the_remedy
    err = block_as(LIGHT)[:err]

    assert_includes err, PRIMARY,
                     "the refusal must NAME the verdict owner — 'ask the holder' is useless " \
                     "without a them"
    assert_includes err, LIGHT,
                     "and it must name who was refused, so the light can see it was not authorised"
    assert_includes err, "does not hold the verdict",
                     "it must say WHAT it is refusing on, not merely that it refused"
    assert_match(/scout report/i, err,
                 "and route the light to what it MAY do — a refusal with no way forward " \
                 "is how an agent invents one")
    assert_includes err, "bin/task note #{SLUG}",
                     "the way to record a finding WITHOUT spending the bounce must be pasteable"
  end

  # ── THE OTHER SIDE OF THE CONTRACT ──────────────────────────────────────────
  #
  # Without these, every assertion above would pass against a gate that refuses
  # UNCONDITIONALLY — which would wedge every legitimate bounce on the board.

  def test_integration_the_verdict_owner_s_own_rework_block_lands
    result = block_as(PRIMARY)

    assert_equal 0, result[:status].exitstatus,
                 "the review claim's own holder OWNS the verdict; refusing them would " \
                 "wedge every legitimate send-back"
    refute_empty result[:writes], "and their block must actually reach the board"
  end

  def test_integration_a_rework_block_with_no_review_in_flight_is_not_gated
    result = block_as(LIGHT, holder: nil)

    assert_equal 0, result[:status].exitstatus,
                 "no live review means no verdict owner to usurp — Avi's QA rework and a " \
                 "builder's own block must stay open"
    refute_empty result[:writes], "and that block must land"
  end

  # SCOPE. `dependency` IS the escalation the breaker routes a deadlock to, and
  # `environment` is a blocked desk, not a send-back. Neither spends a bounce, so
  # neither may be gated — gating them would take the escalation away from the one
  # agent most likely to need it.
  def test_integration_a_non_rework_block_is_not_gated
    %w[dependency environment].each do |kind|
      result = block_as(LIGHT, kind: kind)

      assert_equal 0, result[:status].exitstatus,
                   "--kind #{kind} spends no bounce, so the verdict-owner gate must not " \
                   "fire on it"
    end
  end

  # ── IGNORANCE IS NOT PERMISSION ─────────────────────────────────────────────
  #
  # Both branches mirror the posture the breaker's OWN read already takes one seam
  # over: `bounces` raises on an unreadable ledger rather than counting zero, because
  # "UNKNOWN is NOT clear". Refusing costs the caller nothing they did not already
  # owe — the block needs the same board and the same token to write.

  def test_integration_an_unreadable_review_claim_refuses
    result = block_as(LIGHT, claim_status: 500)

    refute_equal 0, result[:status].exitstatus,
                 "a claim read we could not trust must not read as 'nobody is reviewing' — " \
                 "that is the silent-zero the breaker exists to refuse, one seam out"
    assert_empty result[:writes], "and it must not write on an unverified answer"
  end

  def test_integration_a_live_review_naming_no_owner_refuses
    result = block_as(LIGHT, holder: { "live" => true, "agent" => nil })

    refute_equal 0, result[:status].exitstatus,
                 "a live review whose claim names no soul cannot authorise anyone; the " \
                 "bounce is spent on a verdict nobody is recorded as owning"
    assert_empty result[:writes], "and nothing may land"
  end

  # ── DRIVING THE REAL BINARY ─────────────────────────────────────────────────

  # Run `bin/task block <slug> --kind rework --agent <soul>` against a board whose
  # review claim is held by PRIMARY, and return the exit status, stderr, and every
  # write the CLI sent.
  #
  # The child env goes through BOTH sandboxes: SessionEnv.neutralized scrubs the
  # operator's ambient session before opting this run in to a fake one, and
  # TaskUsageSandboxEnv.child_env pins the usage store, transcript root, and HOME
  # inside a tmpdir. The suite arms TASK_USAGE_SANDBOX process-wide, so an unpinned
  # child ABORTS before it reaches the gate — on a different exit code and an empty
  # write log, which would make two of these tests pass for the wrong reason.
  def block_as(soul, kind: "rework", holder: :default, claim_status: 200,
               session: LIGHT_SESSION, nonce: LIGHT_NONCE)
    holder = default_holder if holder == :default
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => session, "TASK_CLAIM_NONCE" => nonce
        )
      )

      with_board_sink(writes, holder: holder, claim_status: claim_status) do |base|
        _out, err, status = Open3.capture3(
          env.merge("TASK_API_BASE" => base),
          BIN, "block", SLUG, "--kind", kind, "--agent", soul,
          "--summary", "Probe send back now", "--feedback", "probe feedback"
        )
      end

      { status: status, err: err, writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  def default_holder
    { "task_slug" => SLUG, "session" => HOLDER_SESSION, "agent" => PRIMARY,
      "label" => "carl", "expires_at" => (Time.now + 90).utc.iso8601,
      "heartbeat_age" => 3, "live" => true }
  end

  # A board answering every call `block` makes. ROUTING BY PATH MATTERS: a sink that
  # returns one body for everything answers /auth with a task and bin/task dies on a
  # missing "token", which would look like a refusal.
  #
  # ONLY THE MUTATIONS ARE RECORDED (PATCH /block, POST /activities). The auth POST
  # happens on every run, refused or not, so counting it would make the "no write"
  # assertion unfalsifiable.
  def with_board_sink(writes, holder:, claim_status:)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        path = request.split(/\s+/)[1].to_s
        verb = request.split(/\s+/)[0].to_s
        writes << payload if payload && (verb == "PATCH" || (verb == "POST" && path.include?("/activities")))

        code, body = respond(verb, path, holder, claim_status)
        client.write("HTTP/1.1 #{code} #{code == 200 ? "OK" : "Internal Server Error"}\r\n" \
                     "Content-Type: application/json\r\n" \
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

  def respond(_verb, path, holder, claim_status)
    case path
    when %r{/api/v1/auth}          then [200, { token: "sink-bearer" }.to_json]
    when %r{/review_claim}
      return [claim_status, { error: "boom" }.to_json] unless claim_status == 200

      [200, { data: { holder: holder } }.to_json]
    # The ledger reads CLEAR, so nothing here is decided by the circuit breaker —
    # a light that got through would land a write, not be caught by the budget.
    when %r{/api/v1/activities}    then [200, { data: [], meta: { total: 0 } }.to_json]
    else [200, task_body]
    end
  end

  def task_body
    { data: { slug: SLUG, stage: "submitted", title: "Probe Review",
              metadata: { devops: { kind: "bug", repositories: ["mcritchie-studio"],
                                    worktree_slug: SLUG } } } }.to_json
  end
end

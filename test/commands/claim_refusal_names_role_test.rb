# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"

# [integration] The build-claim refusal NAMES THE HOLDER'S ROLE, and routes on it.
#
# THE NEAR-MISS (2026-09-01). `bin/ship` refused a held task with "Ship must not
# hand off another builder's work — take the task over first (--steal)". Every fact
# in that sentence was true and the sentence was still wrong: it describes a rival
# BUILDER, and the holder was a REVIEWER.
#
# THE TWO CASES ARE NOT SYMMETRIC, which is why the routing has to be in the
# message rather than in the reader's judgement. Two builders racing cost a rebase.
# Stealing a task mid-review VOIDS THE NO-SELF-REVIEW GUARANTEE for that review and
# STRANDS the reviewer's verdict — their gate conclusions are discarded silently,
# and the task can then be reviewed by its own author. Neither is recoverable by
# re-running anything, and neither leaves a trace.
#
# So this file drives the REAL `bin/task` against a board that reports a live review
# and asserts what the refusal actually says. test/lib/claim_holder_test.rb pins the
# decision table at the unit tier; this pins that bin/task is wired to it, reads the
# board's `review_in_progress`, and still refuses without writing.
#
# THE SIBLING CONTRACT (test/commands/task_claim_gate_test.rb) is unchanged and
# still runs: that file pins that the gate REFUSES and sends no PATCH. This one
# pins WHICH refusal it sends.
class ClaimRefusalNamesRoleTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-review-held".freeze

  HOLDER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b".freeze
  HOLDER_NONCE   = "holder01".freeze
  MOVER_SESSION  = "019f4c1d-7b2e-74a2-8f19-2c7d90ab3311".freeze
  MOVER_NONCE    = "mover001".freeze

  # ── A LIVE REVIEW ROUTES TO ASK ─────────────────────────────────────────────

  test "[integration] a reviewer-held task is refused as REVIEWING, not as a rival build" do
    err = move(review_in_progress: true, stage: "submitted")[:err]

    assert_includes err, "REVIEWING it",
                     "the refusal must NAME the role. Naming it is the whole fix — the reader " \
                     "who hit this read the old wording, which names a builder, and nearly stole " \
                     "a task out from under a live review"
    assert_includes err, "bin/task review-claim release #{SLUG}",
                     "the remedy for a live review is to ask the holder to release it"
  end

  test "[integration] the reviewer refusal offers no steal path at all" do
    err = move(review_in_progress: true, stage: "submitted")[:err]

    refute_includes err, "--steal",
                    "the near-miss was a reader acting on the remedy line without re-deriving the " \
                    "role. A --steal anywhere in this message is the line they would have taken"
  end

  test "[integration] the reviewer refusal names WHO to ask" do
    err = move(review_in_progress: true, stage: "submitted")[:err]

    assert_includes err, "carl",
                     "'ask them to release it' is useless without a them — the board publishes " \
                     "the reviewing soul and the refusal must read it"
  end

  test "[integration] the reviewer refusal states what a steal would cost" do
    err = move(review_in_progress: true, stage: "submitted")[:err]

    assert_includes err, "NO-SELF-REVIEW",
                     "a reader told only 'do not' will do it anyway the next time it is " \
                     "inconvenient; the argument is what makes the routing stick"
    assert_includes err, "STRANDS THE REVIEWER'S VERDICT"
  end

  # THE LOAD-BEARING ONE. Every assertion above would also pass against a gate that
  # printed a better message and then carried on.
  test "[integration] the reviewer refusal still sends NO write to the board" do
    result = move(review_in_progress: true, stage: "submitted")

    assert_equal 1, result[:status].exitstatus, "the gate refuses; it does not advise"
    assert_empty result[:writes],
                 "a PATCH here means the gate reworded itself and then claimed the reviewer's task"
  end

  # ── NO REVIEW ROUTES TO STEAL, EXACTLY AS BEFORE ────────────────────────────

  test "[integration] a builder-held task keeps the steal remedy" do
    err = move(review_in_progress: false, review_lease: :none)[:err]

    assert_includes err, "BUILDING it", "the other half of the same naming"
    assert_includes err, "bin/task move #{SLUG} building --steal",
                     "--steal is the correct remedy for the case it was written for; a fix that " \
                     "took it away would wedge every legitimate takeover"
    refute_includes err, "review-claim release",
                     "there is no review to ask about, and offering one sends the reader nowhere"
  end

  # ── AN UNREPORTED ROLE IS AN UNKNOWN, NOT A BUILDER ─────────────────────────

  test "[integration] a board that does not report the role refuses both ways" do
    err = move(review_in_progress: :absent, review_lease: :none)[:err]

    assert_includes err, "DO NOT STEAL UNTIL YOU KNOW",
                     "absence of a signal must never read as an affirmative negative — an unknown " \
                     "routed straight to --steal is the original bug with an extra step"
    assert_includes err, "bin/task review-claim status #{SLUG}",
                     "and it must hand over the command that OBSERVES, rather than leaving the " \
                     "reader to guess"
  end

  # ── NEITHER FACT IS SUFFICIENT ALONE ────────────────────────────────────────
  #
  # `review_in_progress` is the board's own column and it is STAGE-SCOPED:
  # Task#review_in_progress? is false unless the task is `submitted`. A task bounced
  # back to `building` under a still-live review lease therefore answers FALSE while
  # a reviewer is demonstrably holding it — which is exactly the shape a takeover
  # would strand. So the role folds the LEASE too, and either fact saying yes wins.

  test "[integration] a live review lease outranks a false review_in_progress column" do
    err = move(review_in_progress: false, review_lease: :live)[:err]

    assert_includes err, "REVIEWING it",
                     "the board's column is scoped to `submitted`, so a task bounced back to " \
                     "`building` under a live review lease reports false while a reviewer holds " \
                     "it. Trusting that column alone re-opens the bug one stage over"
    refute_includes err, "--steal"
  end

  # THE OTHER DIRECTION: a fact we could not READ is not a fact that said no.
  test "[integration] an unreadable review lease refuses as UNKNOWN, never as a builder" do
    err = move(review_in_progress: false, review_lease: :unreadable)[:err]

    assert_includes err, "DO NOT STEAL UNTIL YOU KNOW",
                     "a board hiccup on the lease read must land on the ask-first route. " \
                     "Collapsing 'we could not check' into 'no review' is the fail-open this " \
                     "whole change exists to close"
  end

  # ── --steal IS STILL THE WAY PAST, AND IT SAYS WHAT IT WAIVES ───────────────

  test "[integration] --steal over a live review proceeds but names the guarantee it waives" do
    result = move(review_in_progress: true, flags: ["--steal"])

    assert_equal 0, result[:status].exitstatus,
                 "--steal remains the operator's override. A gate that refused it outright would " \
                 "be uninstalled the first time somebody had already asked and been told yes"
    refute_empty result[:writes], "and the takeover must actually land"
    assert_includes result[:err], "NO-SELF-REVIEW",
                    "but never SILENTLY — a guarantee waived without a word is one nobody can " \
                    "audit afterwards. Same posture the archive gate takes with --force"
  end

  test "[integration] --steal over a builder claim stays quiet" do
    result = move(review_in_progress: false, review_lease: :none, flags: ["--steal"])

    assert_equal 0, result[:status].exitstatus
    refute_includes result[:err], "NO-SELF-REVIEW",
                    "the ordinary takeover this flag was written for must not be dressed in a " \
                    "warning about a review that is not happening — a warning on every steal is " \
                    "a warning nobody reads"
  end

  private

  # Run `bin/task move <slug> building` against a board holding a LIVE claim from
  # HOLDER_SESSION and reporting `review_in_progress` as given. `:absent` omits the
  # key entirely — the older-board case the UNKNOWN route exists for.
  #
  # Both sandboxes, for the reason task_claim_gate_test.rb records: SessionEnv
  # scrubs the operator's ambient session, and the usage sandbox pins the store —
  # without it the child ABORTS before it ever reaches the gate, and the exit code
  # and empty write log look exactly like a passing refusal.
  def move(review_in_progress:, review_lease: :live, stage: "building", flags: [])
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => MOVER_SESSION, "TASK_CLAIM_NONCE" => MOVER_NONCE
        )
      )

      with_board_sink(writes, review_in_progress, review_lease, stage) do |base|
        _out, err, status = Open3.capture3(env.merge("TASK_API_BASE" => base),
                                           BIN, "move", SLUG, "building", *flags)
      end

      { status: status, err: err, writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  # A board that ROUTES BY PATH: the bearer exchange, the review-claim read, and
  # the task read the gate judges. Routing matters here for a second reason beyond
  # the auth one — the refusal's "ask carl" line comes from the review_claim
  # endpoint, and a sink that answered it with the task body would drop the name
  # while every other assertion went on passing.
  def with_board_sink(writes, review_in_progress, review_lease, stage)
    server = TCPServer.new("127.0.0.1", 0)
    auth = { token: "sink-bearer" }.to_json
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        writes << payload if payload && request.start_with?("PATCH")
        # The review-lease read is the second of the two facts the role folds, so it
        # gets its own scripted answer — including an UNREADABLE one, because "we
        # could not check" must land on the UNKNOWN route rather than on "no review".
        code, body =
          if request.include?("/api/v1/auth") then [200, auth]
          elsif request.include?("/review_claim")
            review_lease == :unreadable ? [500, "{}"] : [200, review_claim_body(review_lease)]
          else [200, task_body(review_in_progress, stage)]
          end
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

  # A task carrying a live build lease from HOLDER_SESSION — the shape the
  # near-miss's task was in: a build claim somebody's status line was still renewing
  # while a reviewer worked the task. `stage: "submitted"` is the near-miss verbatim;
  # the default `building` is what the takeover tests need, because a `--steal` that
  # gets through then read-back-verifies the stage it just wrote.
  #
  # `review_in_progress: :absent` omits the key entirely — the older-board case.
  def task_body(review_in_progress, stage)
    devops = { kind: "bug", repositories: ["mcritchie-studio"], worktree_slug: SLUG,
               claimed_session: HOLDER_SESSION, claim_nonce: HOLDER_NONCE,
               claim_expires_at: (Time.now + 90).utc.iso8601 }
    data = { slug: SLUG, stage: stage, title: "Probe Review Held", metadata: { devops: devops } }
    data[:review_in_progress] = review_in_progress unless review_in_progress == :absent
    { data: data }.to_json
  end

  def review_claim_body(review_lease)
    return { data: { holder: nil } }.to_json if review_lease == :none

    { data: { holder: { task_slug: SLUG, session: HOLDER_SESSION, label: "Gastly", agent: "carl",
                        expires_at: (Time.now + 90).utc.iso8601, heartbeat_age: 30, live: true } } }.to_json
  end
end

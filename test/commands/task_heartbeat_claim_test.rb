# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"

# A HEARTBEAT RENEWS A LEASE. IT NEVER ACQUIRES ONE.
#
# THE DEFECT. `bin/task block <slug> --kind rework` lands the bounced task back on
# `building` and ends with write_feature_marker, repointing the BLOCKING session's
# per-session marker at the task it just sent back. bin/statusline reads that
# marker, sees `stage: building`, and fires `bin/task heartbeat` — from a session
# that never built anything. The task's claim keys were stripped when it moved to
# `submitted`, so the lease read :unclaimed and the heartbeat ADOPTED it, PATCHing
# a claim that named the reviewer's session.
#
# Two things followed from that one write. The board could not tell it from a
# handoff — the lease was rewritten and no soul was named — so it stamped
# `devops.builders_unattributed` with the reviewer's session and
# `bin/reviewer-select` refused the next round, "the AUTHORS ARE UNKNOWN". And the
# reviewer now HELD the build claim, so the documented repair (`bin/task move
# <slug> building --actor <author>`) was itself refused as :held_by_other.
# Measured 2026-09-04: four bounced tasks in one review sitting.
#
# THE ASSERTION THAT SEPARATES THE READINGS IS "NO WRITE", exactly as in
# task_claim_gate_test.rb. Every other observable is identical between a heartbeat
# that declines and one that adopts — it prints nothing either way and exits 0 by
# design (a heartbeat must never disrupt the status line). The PATCH is the only
# thing an adopting heartbeat does that a declining one never does.
#
# AND THE OTHER SIDE OF THE CONTRACT, without which this file would pass against a
# heartbeat that renews NOTHING and quietly expires every builder's desk in the
# fleet: the holder's own renewal must still land, and a bound DESK must still be
# able to re-adopt a lapsed lease.
class TaskHeartbeatClaimTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-heartbeat-task".freeze

  # The session whose status line is firing the heartbeat.
  MINE_SESSION = "019f5d2e-8c3f-75b3-9a2b-e491f22ac822".freeze
  MINE_NONCE   = "mine0001".freeze
  # Somebody else's session, on the record of the task.
  OTHER_SESSION = "019f6e3f-9d40-76c4-8b3c-f5a2033bd933".freeze

  # ── THE REGRESSION ──────────────────────────────────────────────────────────

  test "[integration] a heartbeat on an UNCLAIMED building task writes nothing" do
    # The reviewer's shape exactly: the bounce put the task on `building` with no
    # claim keys, and this session holds nothing and sits at no desk.
    result = heartbeat(claim: nil)

    assert_empty result[:writes],
                 "a heartbeat may extend a lease this session holds; adopting a free one " \
                 "makes any terminal pointed at a `building` task its recorded worker"
  end

  test "[integration] a heartbeat on an EXPIRED foreign claim writes nothing" do
    # :expired is the other disposition that used to fall through to the write —
    # the previous holder's lease lapsed, so the passing session took the desk.
    result = heartbeat(claim: { session: OTHER_SESSION, nonce: "other001", in_seconds: -600 })

    assert_empty result[:writes], "a lapsed claim frees the task for a CLAIM, not for a heartbeat"
  end

  test "[integration] the heartbeat still exits 0 when it declines" do
    # Declining is not an error. bin/statusline fires this on every render; a
    # nonzero exit here would paint a failure into the operator's status line.
    assert_equal 0, heartbeat(claim: nil)[:status].exitstatus
  end

  # ── THE OTHER SIDE OF THE CONTRACT ──────────────────────────────────────────

  test "[integration] the holder's own lease is still renewed" do
    result = heartbeat(claim: { session: MINE_SESSION, nonce: MINE_NONCE, in_seconds: 30 })

    refute_empty result[:writes],
                 "the renewal this command exists for must still land, or every builder's " \
                 "desk lapses at the TTL while they are working"
    claim = result[:writes].last["devops"]
    assert_equal MINE_SESSION, claim["claimed_session"]
    assert Time.parse(claim["claim_expires_at"]) > Time.now + 60,
           "and it must actually EXTEND the lease, not merely rewrite it"
  end

  test "[integration] a bound DESK may still adopt a free lease" do
    # The recovery path a builder depends on: the worktree whose .agent-context.json
    # names this task is evidence that this session is at its workbench, which a
    # reviewer's primary checkout can never produce.
    Dir.mktmpdir do |desk|
      File.write(File.join(desk, ".agent-context.json"), { "task_slug" => SLUG }.to_json)
      result = heartbeat(claim: nil, desk: desk)

      refute_empty result[:writes], "the desk vouches for this session"
      assert_equal MINE_SESSION, result[:writes].last["devops"]["claimed_session"]
    end
  end

  test "[integration] a desk bound to a DIFFERENT task does not vouch" do
    # DeskActivity.desk_root refuses any directory not bound to THIS task. Without
    # this, "pass --desk" would be a universal override and the test above would be
    # proving nothing about binding.
    Dir.mktmpdir do |desk|
      File.write(File.join(desk, ".agent-context.json"), { "task_slug" => "some-other-task" }.to_json)
      result = heartbeat(claim: nil, desk: desk)

      assert_empty result[:writes], "a desk for another task is not evidence about this one"
    end
  end

  private

  # Run `bin/task heartbeat <slug>` against a board serving a `building` task in the
  # given claim state, and return the exit status plus every PATCH the CLI sent.
  # Env handling mirrors task_claim_gate_test.rb: SessionEnv.neutralized scrubs the
  # operator's ambient session before opting in to a fake one, and
  # TaskUsageSandboxEnv.child_env pins the usage store, transcript root, and HOME
  # inside a tmpdir — the suite arms TASK_USAGE_SANDBOX process-wide, so an unpinned
  # child ABORTS before it reaches the code under test and every "no write"
  # assertion here would pass for the wrong reason.
  def heartbeat(claim:, desk: nil)
    Dir.mktmpdir do |dir|
      writes = []
      status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => MINE_SESSION, "TASK_CLAIM_NONCE" => MINE_NONCE
        )
      )
      args = ["heartbeat", SLUG]
      args += ["--desk", desk] if desk

      with_board_sink(writes, task_body(claim)) do |base|
        # cwd is a bare tmpdir, so the no-desk cases resolve no desk from Dir.pwd
        # either — the reviewer's primary checkout, which carries no
        # .agent-context.json for this task.
        _out, _err, status = Open3.capture3(env.merge("TASK_API_BASE" => base),
                                            BIN, *args, chdir: dir)
      end

      { status: status, writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  # A board answering the calls `heartbeat` makes: the bearer exchange (POST /auth)
  # and the task read it judges. ONLY PATCH bodies are recorded — the auth POST
  # happens on every run, declined or not, so counting it would make the "no write"
  # assertion unfalsifiable.
  def with_board_sink(writes, task)
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

  # The task as the board serves it. `building` with the given claim state; a nil
  # claim is the post-`submitted` shape the bounce leaves behind — the claim keys
  # are stripped on any non-building save, so a just-blocked task carries none.
  def task_body(claim)
    devops = { kind: "bug", repositories: ["mcritchie-studio"], worktree_slug: SLUG,
               built_by: "shannon", builders: ["shannon"] }
    if claim
      devops = devops.merge(claimed_session: claim[:session], claim_nonce: claim[:nonce],
                            claim_expires_at: (Time.now + claim[:in_seconds]).utc.iso8601)
    end
    { data: { slug: SLUG, stage: "building", title: "Probe Heartbeat Claim Task",
              metadata: { devops: devops } } }.to_json
  end
end

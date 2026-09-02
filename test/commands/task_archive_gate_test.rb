require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"

# The ARCHIVE holder gate REFUSES. It does not warn and carry on.
#
# THE NEAR-MISS THIS EXISTS TO CATCH (2026-09-01, docs/agents/system/agent-presence.md,
# cost #1). Mr. McRitchie asked that one session's work be HELD. That session could not
# be identified from disk — its task record carried an app and a MASCOT and nothing
# else — and it was resolved only by MESSAGING the peer session to ask who it was. Had
# that session been idle, busy, or unreachable, the work would have been archived and
# the operator's explicit exception would have protected nothing.
#
# `bin/task move <slug> archived` ran the stage move with NO holder check of any kind:
# `enforce_claim_gate!` fires only on `stage == "building"`, so the one transition that
# is TERMINAL and destroys UNCOMMITTED work was the one transition nothing guarded.
#
# THE ASSERTION THAT SEPARATES A GATE FROM A WARNING IS "NO WRITE". A path that warned
# loudly and archived anyway would print the mascot, the missing identity keys, and the
# --force hint — every message assertion below would pass on it. The only thing it does
# that a refusing gate never does is send the PATCH. So the refusal is pinned on the
# ABSENCE of the board write, and the messages are pinned separately as the evidence the
# operator identifies the holder with.
class TaskArchiveGateTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze

  MOVER_SESSION = "019f4c1d-7b2e-74a2-8f19-2c7d90ab3311".freeze
  MOVER_NONCE   = "mover001".freeze
  HOLDER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b".freeze

  # THE NEAR-MISS RECORD, as it actually stood: an app and a mascot, and nothing that
  # names a session. No worktree_slug either — the record simply did not say where the
  # work was, which is the whole reason nobody could find its owner.
  UNIDENTIFIABLE = {
    kind: "bug", repositories: ["mcritchie-studio"],
    mascot: "omanyte", mascot_emoji: "🗿💧", app_color: "#B57EDC"
  }.freeze

  # ── THE REFUSAL ─────────────────────────────────────────────────────────────

  test "[integration] archiving a task whose holder cannot be identified exits 1" do
    result = archive(devops: UNIDENTIFIABLE)

    assert_equal 1, result[:status].exitstatus,
                 "the gate ends in `exit 1`; before this fix the move ran unguarded and exited 0"
  end

  # THE LOAD-BEARING ONE. Everything else here is also true of a path that only warns.
  test "[integration] the refused archive sends NO write to the board" do
    result = archive(devops: UNIDENTIFIABLE)

    assert_empty result[:writes],
                 "a PATCH on this path means the task was ARCHIVED — terminal, and destroying " \
                 "uncommitted work whose owner we just admitted we cannot identify"
  end

  test "[integration] the refusal names what it could not verify" do
    err = archive(devops: UNIDENTIFIABLE)[:err]

    assert_includes err, "CANNOT BE IDENTIFIED", "the refusal must say what it is refusing on"
    assert_includes err, "omanyte",
                     "it must name the paint the record DOES carry — that mascot is the only " \
                     "handle the operator has for going and finding the session"
    assert_includes err, "session_id",
                     "and the identity fact that was missing, or the reader cannot tell what " \
                     "would have satisfied the gate"
    assert_includes err, "bin/agent-presence",
                     "a refusal must say HOW to identify the holder, not merely that one must"
  end

  test "[integration] the refusal offers a pasteable override" do
    err = archive(devops: UNIDENTIFIABLE)[:err]

    assert_includes err, "bin/task move #{SLUG} archived --force",
                     "a refusal with no way forward is a dead end; --force is the human decision " \
                     "seam, exactly as `remove <app> <task> --yes` is for a desk"
  end

  # ── THE OTHER SIDE OF THE SAME CONTRACT ─────────────────────────────────────
  #
  # A test that only proved the refusal would pass just as well against a gate that
  # refuses UNCONDITIONALLY — which would wedge `bin/release archive`, Alex's clean-up
  # SOP, and every honest archive on the board. These pin the gate open where it must
  # be open.

  test "[integration] --force archives anyway and names the grade it overrode" do
    result = archive(devops: UNIDENTIFIABLE, flags: ["--force"])

    assert_equal 0, result[:status].exitstatus, "--force must let the archive through"
    refute_empty result[:writes], "and the stage move must actually land"
    assert_equal "archived", result[:writes].last["stage"]
    assert_includes result[:err], "UNVERIFIABLE",
                     "an override that prints nothing turns the gate into a speed bump nobody " \
                     "remembers clearing — it must name which proof was waived"
  end

  test "[integration] a shipped task archives without a holder check" do
    result = archive(devops: UNIDENTIFIABLE, stage: "shipped")

    assert_equal 0, result[:status].exitstatus,
                 "shipped work is merged to `main` — there is no unmerged work left to destroy, " \
                 "and a gate that blocked this would wedge the DevOps loop's conclusion"
    refute_empty result[:writes]
  end

  test "[integration] a task nobody ever picked up archives" do
    result = archive(devops: { kind: "bug", repositories: ["mcritchie-studio"] })

    assert_equal 0, result[:status].exitstatus,
                 "no session, no mascot, no claim — a gate that refused this would refuse every " \
                 "legitimate archive of an unclaimed idea"
    refute_empty result[:writes]
  end

  # THE REGRESSION FOR THE MEASURED DEFECT (review send-back 1, 2026-09-02). Graded
  # against the live board, the first cut of this gate refused 31 of 34 live tasks;
  # all 31 `:working` refusals were held by the board clock, and 16 of them had NO
  # DESK — provably nothing uncommitted to protect. The fixture serves a board write
  # 12 seconds old, which is the ordinary state of any task Alex's clean-up has just
  # triaged, and is what `holder_liveness_seconds_ago` reports for a task whose only
  # artifact is its own CREATE.
  test "[integration] an identifiable, provably-abandoned holder archives" do
    # A session we CAN check: named, its lease long lapsed, and no desk on this
    # machine. Every channel that attests WORK AT RISK is silent — checked, and found
    # gone — while the board clock reads fresh, as the board's does for every task.
    devops = UNIDENTIFIABLE.merge(
      session_id: HOLDER_SESSION,
      claimed_session: HOLDER_SESSION,
      claim_expires_at: (Time.now - 7200).utc.iso8601,
      worktree_slug: "probe-task-no-such-desk"
    )
    result = archive(devops: devops)

    assert_equal 0, result[:status].exitstatus,
                 "this is exactly what the gate is supposed to let through: a holder we could " \
                 "identify, went and checked, and proved had walked away. A fresh board " \
                 "timestamp is not evidence of work at risk — it is the signal this very " \
                 "verb writes, and holding on it refused 16 desk-less tasks"
    refute_empty result[:writes]
  end

  # THE NARROWING IS NOT A GUTTING. The gate's remaining channels must still stop the
  # archive cold, or this rework has traded one fatal failure for its twin.
  test "[integration] a task whose gate is in flight is still refused" do
    devops = UNIDENTIFIABLE.merge(
      session_id: HOLDER_SESSION, claimed_session: HOLDER_SESSION,
      claim_expires_at: (Time.now - 7200).utc.iso8601,
      worktree_slug: "probe-task-no-such-desk"
    )
    result = archive(devops: devops, gate_in_flight: true)

    assert_equal 1, result[:status].exitstatus,
                 "a cert writes nothing into its desk for up to the measured 94-minute p99, " \
                 "so a quiet desk mid-cert is a working one"
    assert_empty result[:writes]
    assert_includes result[:err], "gate", "and the refusal must name the channel that kept it"
  end

  test "[integration] a task parked on the operator is still refused" do
    devops = UNIDENTIFIABLE.merge(
      session_id: HOLDER_SESSION, claimed_session: HOLDER_SESSION,
      claim_expires_at: (Time.now - 7200).utc.iso8601,
      worktree_slug: "probe-task-no-such-desk", approval_status: "waiting"
    )
    result = archive(devops: devops)

    assert_equal 1, result[:status].exitstatus,
                 "a task waiting on Mr. McRitchie's local validation is blocked on a human, " \
                 "not abandoned — and its work is sitting in front of him"
    assert_empty result[:writes]
    assert_includes result[:err], "approval"
  end

  # ── AND THE GATE MUST NOT LEAK ONTO OTHER TRANSITIONS ───────────────────────

  test "[integration] a non-archive move is not subject to the holder gate" do
    result = archive(devops: UNIDENTIFIABLE, stage: "submitted", to: "reviewed")

    assert_equal 0, result[:status].exitstatus,
                 "only `archived` is terminal and destructive; gating the whole ladder would " \
                 "stall every review handoff on a missing mascot"
    refute_empty result[:writes]
  end

  # ── THE HELD CASE ───────────────────────────────────────────────────────────

  test "[integration] archiving a task a LIVE session holds is refused and names the session" do
    devops = UNIDENTIFIABLE.merge(
      session_id: HOLDER_SESSION, claimed_session: HOLDER_SESSION,
      claim_nonce: "holder01", claim_expires_at: (Time.now + 90).utc.iso8601
    )
    result = archive(devops: devops)

    assert_equal 1, result[:status].exitstatus
    assert_empty result[:writes], "a live holder's uncommitted work must never be archived out from under it"
    assert_includes result[:err], HOLDER_SESSION[-4..], "the refusal must name WHO holds it"
  end

  private

  # Run the real `bin/task move <slug> <to>` against a board serving a task with the
  # given devops, and return the exit status, stderr, and every write the CLI sent.
  #
  # The child env goes through BOTH sandboxes on purpose: SessionEnv.neutralized scrubs
  # the operator's ambient session before opting this run in to a fake one, and
  # TaskUsageSandboxEnv.child_env pins the usage store, transcript root, and HOME inside
  # a tmpdir. The suite arms TASK_USAGE_SANDBOX process-wide, so an unpinned child
  # ABORTS before it ever reaches the gate — producing an exit 1 and an empty write log
  # from a completely different refusal, which would make the two assertions this file
  # turns on pass for the wrong reason. The message assertions are the backstop.
  #
  # CLAUDE_PROJECTS_DIR is pinned into the tmpdir too, so the desk-liveness channel
  # resolves against an empty projects root rather than the developer's real one — a
  # test that read the operator's live .worktrees/ would answer differently on every
  # machine and every day.
  def archive(devops:, stage: "designed", to: "archived", flags: [], gate_in_flight: false)
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => MOVER_SESSION, "TASK_CLAIM_NONCE" => MOVER_NONCE,
          "CLAUDE_PROJECTS_DIR" => dir
        )
      )

      with_board_sink(writes, stage: stage, to: to, devops: devops, gate: gate_in_flight) do |base|
        _out, err, status = Open3.capture3(env.merge("TASK_API_BASE" => base),
                                           BIN, "move", SLUG, to, *flags)
      end

      { status: status, err: err, writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  # A board answering the calls `move` makes: the bearer exchange (POST /auth), the task
  # read the gate judges, and — only if the gate lets it through — the PATCH.
  #
  # THE STAGE FLIPS ONCE A PATCH LANDS, because the CLI reads the task back after the
  # write and refuses to report a move that did not persist. A sink that always served
  # the ORIGINAL stage would fail that read-back on every permitted run, and the
  # "archive proceeds" tests would go red for a reason that has nothing to do with the
  # gate. Serving the pre-move stage to the gate and the post-move stage to the
  # read-back is what the real board does.
  #
  # ONLY PATCH BODIES ARE RECORDED. The auth POST happens on every run, refused or not,
  # so counting it would make the "no write" assertion unfalsifiable.
  def with_board_sink(writes, stage:, to:, devops:, gate: false)
    server = TCPServer.new("127.0.0.1", 0)
    auth = { token: "sink-bearer" }.to_json
    moved = false
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        if payload && request.start_with?("PATCH")
          writes << payload
          moved = true
        end
        body =
          if request.include?("/api/v1/auth")
            auth
          else
            task_body(moved ? to : stage, devops, gate: gate)
          end
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

  # THE FIXTURE MUST SERVE WHAT THE REAL BOARD SERVES, or the suite is blind to the
  # bug in exactly the way this one was. Api::V1::TasksController always sends
  # `holder_liveness_seconds_ago` and `holder_gate_in_flight`; this sink used to omit
  # both, so every run reached the gate with the board clock reading nil — the ONE
  # value at which the old, over-wide gate behaved correctly. Nine integration tests
  # passed against a gate that refused 31 of 34 real tasks, because the fixture could
  # not express the defect.
  #
  # So the default is FRESH (a board write seconds ago), which is what the board
  # returns for any task that has just been created, moved, noted, or triaged — the
  # ordinary state of everything Alex's clean-up sweeps. A test wanting the old blind
  # reading has to ask for it by name.
  def task_body(stage, devops, liveness: 12, gate: false)
    { data: { slug: SLUG, stage: stage, title: "Probe Task",
              holder_liveness_seconds_ago: liveness, progress_seconds_ago: liveness,
              holder_gate_in_flight: gate, gate_in_flight: gate,
              metadata: { devops: devops } } }.to_json
  end
end

require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"
require_relative "../support/fake_desk"

# The ARCHIVE holder gate REFUSES. It does not warn and carry on.
#
# `archived` is terminal, and the one thing it can destroy is UNCOMMITTED work in a
# desk. Since devops-v3 piece 4b-ii-b the gate refuses exactly that case: a desk bound
# to the task on this machine has uncommitted changes (DeskClaim.dirty_bound). The
# graded gate before it (held / working / unverifiable, keyed on mascots, leases and
# board liveness) is deleted.
#
# THE ASSERTION THAT SEPARATES A GATE FROM A WARNING IS "NO WRITE". A path that warned
# loudly and archived anyway would pass every message assertion below; the only thing
# it does that a refusing gate never does is send the PATCH.
class TaskArchiveGateTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze

  MOVER_SESSION = "019f4c1d-7b2e-74a2-8f19-2c7d90ab3311".freeze
  MOVER_NONCE   = "mover001".freeze
  HOLDER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b".freeze

  # A record carrying only an app and a mascot — which the old gate refused as
  # UNIDENTIFIABLE. With no dirty desk it now archives.
  PAINTED = {
    kind: "bug", repositories: ["mcritchie-studio"],
    mascot: "omanyte", mascot_emoji: "🗿💧", app_color: "#B57EDC"
  }.freeze

  # ── THE REFUSAL: a dirty desk bound to the task ─────────────────────────────

  test "[integration] a dirty bound desk refuses the archive and sends NO write" do
    result = archive(devops: PAINTED, desk: :dirty)

    assert_equal 1, result[:status].exitstatus
    assert_empty result[:writes], "a PATCH here would archive over uncommitted work"
    assert_includes result[:err], "uncommitted changes"
    assert_includes result[:err], ".worktrees/#{SLUG}", "the refusal names the desk"
    assert_includes result[:err], "bin/task move #{SLUG} archived --force", "and the override"
  end

  test "[integration] a dirty bound desk refuses even a shipped task" do
    result = archive(devops: PAINTED, stage: "shipped", desk: :dirty)

    assert_equal 1, result[:status].exitstatus
    assert_empty result[:writes]
  end

  test "[integration] --force archives over a dirty desk and says so" do
    result = archive(devops: PAINTED, desk: :dirty, flags: ["--force"])

    assert_equal 0, result[:status].exitstatus, result[:err]
    refute_empty result[:writes]
    assert_includes result[:err], "--force"
  end

  # ── THE GATE MUST ALSO OPEN ─────────────────────────────────────────────────

  test "[integration] a clean bound desk archives" do
    result = archive(devops: PAINTED, desk: :clean)

    assert_equal 0, result[:status].exitstatus, result[:err]
    refute_empty result[:writes]
  end

  test "[integration] a task with only a mascot and no desk archives" do
    result = archive(devops: PAINTED)

    assert_equal 0, result[:status].exitstatus, result[:err]
    refute_empty result[:writes]
  end

  test "[integration] a non-archive move is not subject to the holder gate" do
    result = archive(devops: PAINTED, stage: "submitted", to: "reviewed", desk: :dirty)

    assert_equal 0, result[:status].exitstatus, result[:err]
    refute_empty result[:writes]
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
  # CLAUDE_PROJECTS_DIR is pinned into the tmpdir too, so the desk read resolves
  # against a projects root holding only the desk this test builds (`desk:` :dirty or
  # :clean), never the developer's real .worktrees/.
  def archive(devops:, stage: "designed", to: "archived", flags: [], gate_in_flight: false, desk: nil)
    Dir.mktmpdir do |dir|
      FakeDesk.build(dir, task_slug: SLUG, session: HOLDER_SESSION, dirty: desk == :dirty) if desk
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

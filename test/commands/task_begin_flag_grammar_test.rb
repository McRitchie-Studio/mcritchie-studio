require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "fileutils"
require "json"

# [unit] `bin/task begin`'s flags must LAND or REFUSE — never be dropped in silence.
#
# THE DEFECT THIS EXISTS TO CATCH, measured 2026-08-29. `begin` has two forms:
# a CREATE (`--title …`, which forwards create flags) and a RESUME
# (`begin <slug>`, which accepted only --steal). The documented fast lane says to
# pass `--agent <soul>`, and on the RESUME form that flag was accepted, ignored,
# and never mentioned again. Four tasks resumed that way came out with
# agent_slug nil AND devops.built_by nil, while the same flag on a create
# stamped both.
#
# WHY A DROPPED FLAG IS WORSE THAN A FAILED ONE. `devops.built_by` is the ONLY
# input `bin/reviewer-select` can use to keep a soul off their own PR. Blank, it
# REFUSES to pick and a human hand-picks instead — and a hand-picked light once
# turned out to be the PR's own author. `begin` printed the worktree and reported
# success either way, so the builder had no signal; the failure surfaced a day
# later, in review, wearing a different costume.
#
# EVERY ASSERTION HERE RUNS OFF-NETWORK by construction: both refusals happen in
# argument parsing, before `begin` resolves a slug against the board. TASK_API_BASE
# is pinned at an unroutable address so a REGRESSION that defers either check
# until after the lookup fails loudly here instead of silently reaching prod.
class TaskBeginFlagGrammarTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  # Loopback on a port nothing listens on: the connection is REFUSED immediately.
  # An unroutable address (TEST-NET-1) would blackhole and hang the suite instead —
  # measured. The point is the same either way: a check that wrongly moved below
  # the API call cannot accidentally pass by reaching a real board.
  OFFLINE = { "TASK_API_BASE" => "http://127.0.0.1:1", "TASK_SKIP_MARKER" => "1" }.freeze

  test "a create flag on the resume form is refused, not dropped" do
    _out, err, status = run_task("begin", "some-slug", "--shape", "backend")

    refute status.success?, "a flag begin cannot honour must fail the command"
    assert_includes err, "unknown flag", "the refusal must name the flag as unknown here"
    assert_includes err, "--shape"
    assert_includes err, "bin/task update", "and must name where the flag DOES belong"
  end

  # THE FLAG THE FAST LANE ACTUALLY DOCUMENTS. If this ever starts refusing, the
  # published workflow breaks for every resumed task — so the grammar is pinned
  # from both sides, not just the refusing one.
  test "the builder flag is accepted by the resume form" do
    _out, err, _status = run_task("begin", "no-such-task-xyz", "--agent", "alex")

    refute_includes err, "unknown flag",
                     "--agent is forwarded to the claim as --actor; refusing it would break " \
                     "the documented fast lane for every resumed task"
  end

  # SHAPE, NOT MEMBERSHIP. The CLI holds no Rails constants and cannot see the
  # Agent table — and a missing Agent row is NOT what breaks the stamp (every soul
  # is seeded). What breaks it is a value outside SOUL_SLUG, which
  # Task#builder_to_stamp tests before it writes built_by. `--agent Steffon` and
  # `--agent turf_monster` are the realistic spellings that silently no-op.
  test "an agent value that could never stamp is refused at the door" do
    ["Steffon", "turf_monster", "carl2"].each do |bad|
      _out, err, status = run_task("create", "--title", "Probe Three Words", "--agent", bad)

      refute status.success?, "#{bad.inspect} cannot match SOUL_SLUG, so it must not be accepted"
      assert_includes err, "must be a soul slug", "the refusal must say what shape is required"
      assert_includes err, "built_by", "and why it matters — the stamp is the whole point"
    end
  end

  test "a soul-shaped agent value passes validation" do
    _out, err, _status = run_task("create", "--title", "Probe Three Words", "--agent", "turf-monster")

    refute_includes err, "must be a soul slug",
                     "a hyphenated soul is the shape Task::SOUL_SLUG accepts"
  end

  # GUARD THE MIRROR. bin/task carries its own copy of SOUL_SLUG because it holds
  # no Rails constants. Two copies of one contract drift, and the drift is silent:
  # the CLI would accept a value the model then refuses to stamp, which is exactly
  # the failure this whole task exists to remove.
  test "the CLI soul pattern still matches the model it mirrors" do
    cli = File.read(BIN)[/^SOUL_SLUG = (.+)$/, 1]

    assert_equal Task::SOUL_SLUG.inspect, cli.strip,
                 "bin/task's SOUL_SLUG must stay identical to Task::SOUL_SLUG"
  end

  # ── THE FORWARD ITSELF (acceptance criterion 2) ─────────────────────────────
  #
  # The grammar tests above prove --agent is ACCEPTED. This proves it is USED.
  # Without the forward, begin's child `move` defaults its actor to the session
  # UUID — not a soul — so Task#builder_to_stamp rule 1 cannot fire; and on a
  # resume agent_slug is nil, so rule 4 cannot either. That is the whole of why
  # begin had no path to built_by, and an accepted-but-unused flag would satisfy
  # every assertion above while fixing nothing.
  #
  # The child move is intercepted through TASK_BEGIN_MOVE_BIN and its argv
  # recorded, so this observes the ACTUAL command begin builds rather than the
  # source line that builds it.
  test "the builder is forwarded to the claim as --actor" do
    argv = captured_move_argv("--agent", "carl")

    assert_includes argv, "--actor", "begin must name the builder on the child move"
    assert_equal "carl", argv[argv.index("--actor") + 1]
    assert_includes argv, "building", "and it is still the build claim it forwards onto"
  end

  # No builder, no actor — begin must not invent one. A fabricated actor would be
  # worse than a blank: reviewer-select REFUSES a blank builder (fail-closed) but
  # would happily exclude a wrong soul, silently, and pick the PR's own author.
  test "no builder means no actor is invented" do
    refute_includes captured_move_argv, "--actor",
                    "a blank built_by fails review CLOSED; a WRONG one fails it open"
  end


  # ── EVERY ADVERTISED FLAG MUST BE WIRED ─────────────────────────────────────
  #
  # FOUND IN REVIEW of this very PR, and it is the same defect the PR removes.
  # An earlier draft listed --dev-size as accepted on the resume form and then
  # dropped it on the already-`building` RENEWAL branch, where `dev_size` never
  # appeared at all. Accepting a flag and ignoring it is exactly the silent drop
  # this task exists to end — advertising it is arguably worse than refusing it,
  # because the caller has been told it works.
  #
  # The same review found --repo had regressed the OTHER way: it is genuinely read
  # on the shared path (as lists["repositories"], to pick which app's desk is
  # allocated), and the guard turned a working flag into a refused one.
  # NOTE WHICH BRANCH THIS DRIVES, because the first version of this test drove the
  # wrong one and PASSED WITH THE FIX REVERTED. `begin` claims two ways: a task in
  # `designed` gets a child `move` (argv, already correct), and a task already in
  # `building` gets an inline PATCH — and the PATCH was the branch that dropped
  # --dev-size. A test against the child-move path cannot express the defect at all.
  test "the resume form honours the size it advertises on the renewal branch" do
    body = captured_renewal_body("--agent", "carl", "--dev-size", "large")

    assert_equal "large", body["dev_size"],
                 "a resume of an ALREADY-building task must send the size it accepted — " \
                 "dev_size rides beside devops as a top-level column, the way `move` sends it"
  end

  # THE HEADLINE LINE, and nothing pinned it until this test. FOUND IN REVIEW
  # (round 2): deleting the renewal branch's `event.actor` forward left all 31
  # tests across the three relevant files GREEN — the SAME shape round 1 was
  # blocked for (a renewal-branch behaviour whose only test drove the child-move
  # branch), on the sibling line of the same if/else. Without the forward, a
  # resume of an ALREADY-building task renews the claim with no actor:
  # Task#builder_to_stamp rule 1 cannot fire, and a resume sets no agent_slug so
  # rule 4 cannot either — built_by stays blank, which is the whole defect this
  # task exists to remove.
  test "the renewal branch names the builder as the event actor" do
    body = captured_renewal_body("--agent", "carl")

    assert_equal "carl", body.dig("event", "actor"),
                 "a resume of an already-building task must name the builder on the " \
                 "claim renewal — it is the ONLY path to built_by on that branch"
  end

  test "the child-move branch forwards the size too" do
    argv = captured_move_argv("--agent", "carl", "--dev-size", "large")

    assert_includes argv, "--dev-size"
    assert_equal "large", argv[argv.index("--dev-size") + 1]
  end

  test "the repo flag is accepted because the resume path reads it" do
    _out, err, _status = run_task("begin", "no-such-task-xyz", "--repo", "turf-monster")

    refute_includes err, "unknown flag",
                    "--repo is read on the shared path to choose which app's desk is " \
                    "allocated; refusing it regressed a flag that worked"
  end

  # THE GUARD ON THE GUARD. Anything the resume form advertises has to be read
  # somewhere in the `begin` block, or the whitelist is lying to its caller. This
  # is a source-level check on purpose: it is the one assertion that fails when a
  # future editor adds a flag to the list and forgets to wire it, which is the
  # mistake that was actually made here.
  test "every flag the resume form advertises is read by begin" do
    body = File.read(BIN)[/^when "begin"$.*?^when "/m] or flunk "could not isolate the begin block"
    advertised = File.read(BIN)[/resume_flags = %w\[([^\]]+)\]/, 1].split
    reads = { "--slug" => /top\["slug"\]/, "--repo" => /lists\["repositories"\]/,
              "--agent" => /top\["agent"\]/, "--dev-size" => /top\["dev_size"\]/,
              "--steal" => /steal/ }

    advertised.each do |flag|
      pattern = reads.fetch(flag) { flunk "#{flag} is advertised but this test has no reader for it — wire it, then add one" }
      assert_match pattern, body,
                   "#{flag} is advertised by the resume form but nothing in `begin` reads it — " \
                   "an accepted-and-ignored flag is the silent drop this task removes"
    end
  end

  private

  # Run `begin` against a board sink this test owns, with the worktree, preflight
  # and move children replaced by recording stubs, and return the argv the child
  # `move` was called with.
  def captured_move_argv(*extra)
    Dir.mktmpdir do |dir|
      move_log = File.join(dir, "move-argv")
      stub(dir, "move-stub", "printf '%s\n' \"$@\" > #{move_log}")
      stub(dir, "worktree-stub", "echo #{dir}")
      stub(dir, "preflight-stub", "exit 0")

      with_board_sink(dir) do |base|
        Open3.capture3(
          { "TASK_API_BASE" => base, "AGENT_API_SECRET" => "not-a-real-secret",
            "TASK_SKIP_MARKER" => "1", "TASK_BEGIN_PROJECTS_DIR" => dir,
            "TASK_BEGIN_MOVE_BIN" => File.join(dir, "move-stub"),
            "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
            "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub") },
          BIN, "begin", "probe-task", *extra
        )
      end

      File.exist?(move_log) ? File.read(move_log).split("\n") : []
    end
  end

  # Drive the RENEWAL branch: the task is already `building`, and a session identity
  # is present so `begin` writes the claim rather than leaving it alone. Returns the
  # decoded body of the LAST PATCH it sent.
  def captured_renewal_body(*extra)
    Dir.mktmpdir do |dir|
      stub(dir, "worktree-stub", "echo #{dir}")
      stub(dir, "preflight-stub", "exit 0")
      writes = []

      with_board_sink(dir, stage: "building", writes: writes) do |base|
        Open3.capture3(
          { "TASK_API_BASE" => base, "AGENT_API_SECRET" => "not-a-real-secret",
            "TASK_SKIP_MARKER" => "1", "TASK_BEGIN_PROJECTS_DIR" => dir,
            "CLAUDE_CODE_SESSION_ID" => "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b",
            "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
            "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub") },
          BIN, "begin", "probe-task", "--steal", *extra
        )
      end

      parsed = writes.filter_map { |w| JSON.parse(w) rescue nil }
      flunk "the renewal branch sent no PATCH — the test never reached the code it targets" if parsed.empty?
      parsed.last
    end
  end

  # A board answering the two calls `begin` makes before it claims: the bearer
  # exchange (/auth), then the task read. The task comes back in `designed`, so
  # begin takes the child-move branch rather than the already-building renewal
  # branch. ROUTING BY PATH MATTERS — a sink that returns one body for every
  # request answers /auth with a task and bin/task dies on a missing "token".
  def with_board_sink(_dir, stage: "designed", writes: nil)
    server = TCPServer.new("127.0.0.1", 0)
    task = { data: { slug: "probe-task", stage: stage, title: "Probe Task",
                     metadata: { devops: { worktree_slug: "probe-task",
                                           repositories: ["mcritchie-studio"] } } } }.to_json
    auth = { token: "sink-bearer" }.to_json
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        # Drain headers, keeping Content-Length so a PATCH body can be READ rather
        # than discarded — the renewal branch's payload is the assertion.
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        writes << payload if writes && payload && request.start_with?("PATCH")
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

  def stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def run_task(*args)
    Open3.capture3(OFFLINE, BIN, *args)
  end
end

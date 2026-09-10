# frozen_string_literal: true

# Guard for the `approval_request_dropped_at` row in
# docs/agents/modules/devops-task-board.md — the row agents read to know WHEN
# `bin/task move` announces a discarded operator-approval request.
#
# WHY IT PINS THE BINARY AND NOT THE PROSE. Until 2026-09-08 that row ended
# "Anything it cannot determine resolves to warning." The binary does not: the
# verdict is `pre-read said waiting` OR `the drop stamp moved across the write`,
# and when NEITHER half can see the drop it stays quiet. Agents read this file AS
# BEHAVIOUR, so an overstated guarantee teaches a false one. A test that greps for
# the corrected sentence would die at the next reword and would never notice the
# CODE moving underneath it — so this file MEASURES the binary across the whole
# board-state matrix and asserts the doc enumerates exactly what it found. Close a
# residual in bin/task and this goes red asking the doc to say so; widen the
# silence and it goes red too.
#
# Standalone by construction (no test_helper, no Rails, no network): it shells out
# to the REAL bin/task against a localhost stub board, the same way
# test/lib/task_move_approval_drop_test.rb does. The stub board is duplicated here
# rather than extracted because a `docs`-shaped diff may add nothing but prose and
# `test/docs/*_test.rb` — a shared helper would have to live elsewhere.
#
#   ruby -Itest test/docs/approval_drop_warning_docs_test.rb
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

class ApprovalDropWarningDocsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin", "task")
  DOC = File.join(ROOT, "docs", "agents", "modules", "devops-task-board.md")
  SLUG = "demo-slug"
  # The stub board's copy of Task::APPROVAL_REQUEST_STAGES — a save landing
  # anywhere else settles a waiting request. Pinned against the real constant by
  # test/models/task_approval_request_guard_test.rb, which runs in a lane that HAS
  # Rails; this file drives the CLI as a subprocess and never reads Task itself.
  SETTLE_EXEMPT_STAGES = %w[designed building submitted].freeze
  # A FIXED stamp, not Time.now: the same-second collision below has to be exact,
  # and seeding it off a real clock would make the case a coin flip on the second
  # boundary. The CLI compares the two renderings as strings; identical strings
  # are the whole of what "the same second" means to it.
  STAMP = "2026-09-08T12:00:00Z"
  EARLIER_STAMP = "2026-09-08T11:45:00Z"

  # EVERY board state the warning can face, driven through the real binary.
  # `drop:` records whether a request was REALLY discarded by this move — the
  # question the warning exists to answer — so the residuals (a real drop the CLI
  # cannot see) fall out of the measurement rather than being asserted by hand.
  SCENARIOS = {
    pre_read_waiting_and_receipt: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "waiting" } }
    },
    pre_read_waiting_and_no_receipt: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "waiting" }, stamps_receipt: false }
    },
    unreadable_pre_read_and_receipt: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "waiting" }, fail_get: 503 }
    },
    unreadable_pre_read_and_no_receipt: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "waiting" }, fail_get: 503,
              stamps_receipt: false }
    },
    racing_writer_and_moved_stamp: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "none",
                        "approval_request_dropped_at" => EARLIER_STAMP },
              devops_after: { "kind" => "feature", "approval_status" => "none",
                              "approval_request_dropped_at" => STAMP } }
    },
    racing_writer_and_identical_stamp: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "none",
                        "approval_request_dropped_at" => STAMP },
              devops_after: { "kind" => "feature", "approval_status" => "none",
                              "approval_request_dropped_at" => STAMP } }
    },
    racing_writer_and_no_receipt: {
      drop: true, dest: "reviewed",
      opts: { devops: { "kind" => "feature", "approval_status" => "none" },
              devops_after: { "kind" => "feature", "approval_status" => "none" } }
    },
    no_request_at_all: {
      drop: false, dest: "reviewed",
      opts: { devops: { "kind" => "feature" } }
    },
    move_into_a_stage_that_holds_requests: {
      drop: false, dest: "building",
      opts: { devops: { "kind" => "feature", "approval_status" => "none",
                        "approval_request_dropped_at" => STAMP },
              stub_stage: "reviewed" }
    }
  }.freeze

  # The drops the binary CANNOT see, measured 2026-09-08 against the live
  # `accepted` binary. Each entry pairs the residual with the phrase the doc row
  # must carry for it. The regexes are deliberately loose — the row may be
  # reworded freely; what it may not do is stop naming a residual that still
  # exists, or keep naming one that has been closed.
  DOCUMENTED_RESIDUALS = {
    unreadable_pre_read_and_no_receipt: /unreadable/i,
    racing_writer_and_identical_stamp: /same second/i,
    racing_writer_and_no_receipt: /too old to write/i
  }.freeze

  # The claim this file was written to retire. Kept as a tripwire against a revert.
  RETIRED_CLAIM = /anything it cannot determine resolves to warning/i

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # --- the load-bearing assertion: the doc's enumeration vs. the binary's ---

  def test_the_documented_residuals_are_exactly_the_drops_the_binary_cannot_see
    measured = measure_matrix

    # FLOOR. A harness that fails to launch the binary, or a stub that 500s every
    # request, would otherwise report "no warnings" and pass having proved nothing.
    assert_equal SCENARIOS.keys.sort, measured.keys.sort, "every scenario must have been driven"
    assert_includes measured.values, :warn, "the matrix must contain at least one announced drop"
    assert_includes measured.values, :silent, "the matrix must contain at least one silent move"

    silent_drops = SCENARIOS.keys.select { |k| SCENARIOS[k][:drop] && measured[k] == :silent }

    assert_equal DOCUMENTED_RESIDUALS.keys.sort, silent_drops.sort,
                 "the drops bin/task cannot see changed — update the " \
                 "approval_request_dropped_at row in #{rel(DOC)} (and this list) to match"
  end

  def test_the_doc_row_names_every_residual_the_binary_still_has
    row = dropped_at_row

    DOCUMENTED_RESIDUALS.each do |residual, phrase|
      assert_match phrase, row, "the row must name the #{residual} residual"
    end
    refute_match RETIRED_CLAIM, row,
                 "the row claimed every unknown resolves to a warning; three of them resolve to silence"
  end

  def test_the_doc_row_tells_a_reader_that_silence_is_not_proof
    assert_match(/silent|silence|quiet/i, dropped_at_row,
                 "a reader who trusts a quiet move has to be told the quiet can be wrong")
  end

  # --- the recovery path: every command it prints has to RUN ---
  #
  # Asserting the step is PRESENT proves only that a string is present. The CLI's
  # own warning carries this trap in a comment: its first draft advertised
  # `bin/task move <slug> building --approval waiting`, a flag `move` does not
  # have, so the one command a stuck reader would paste died on unknown_flag!.

  def test_the_recovery_step_prints_commands_that_actually_run
    commands = recovery_commands

    # FLOOR — an extraction that matched nothing would pass the loop vacuously.
    assert_equal 2, commands.size, "the recovery step names the move and the re-request"
    assert(commands.all? { |c| c.start_with?("bin/task ") }, "both are bin/task commands: #{commands.inspect}")

    # Run them IN THE PRINTED ORDER against one board that starts where a stranded
    # operator actually is — `reviewed`, the first stage past the request window
    # since `submitted` joined it on 2026-09-09 — and judge the END STATE, not the
    # commands. The order is the whole remedy: the move has to land the task where
    # a request is legal before the request can stick, and the stub enforces
    # Task.guard_approval_request_stage! so the reverse order 422s here exactly as
    # it does against the real board.
    with_stub_board(stub_stage: "reviewed", devops: { "kind" => "feature" }) do |run|
      commands.each do |command|
        args = command.sub("bin/task ", "").split(" ").map { |a| a.gsub("<task-slug>", SLUG) }
        _out, err, status = run.call(args)

        assert status.success?, "`#{command}` failed: #{err}"
      end

      assert_equal "building", @persisted_stage, "the remedy has to land the task where a request is legal"
      assert_equal "waiting", @stub_devops["approval_status"], "the remedy has to leave the request LIVE"
    end
  end

  private

  def rel(path) = path.sub("#{ROOT}/", "")

  def doc_body = @doc_body ||= File.read(DOC)

  # The table row under test. Floored on length so a renamed field, or a table
  # collapsed into prose, reddens here rather than passing on an empty string.
  def dropped_at_row
    @dropped_at_row ||= begin
      row = doc_body.lines.find { |l| l.start_with?("| `approval_request_dropped_at` |") }

      refute_nil row, "no `approval_request_dropped_at` row in #{rel(DOC)}"
      assert_operator row.length, :>, 400, "the row is too short to be the documented rule"
      row
    end
  end

  # The commands the Operator Validation Gate's recovery step prints, in order.
  # Read out of the fenced block that follows the step, so the prose around them
  # may be rewritten freely and the commands are still the thing under test.
  def recovery_commands
    section = doc_body[/^## Operator Validation Gate$.*?(?=^## )/m].to_s

    refute_empty section, "no Operator Validation Gate section in #{rel(DOC)}"
    # Anchored on the REMEDY'S OWN WORDS, not on the condition that precedes them.
    # The first cut matched the literal "**Already handed off?" and went empty the
    # day the condition changed — `submitted` joined the request window on
    # 2026-09-09, so a handoff no longer strands anybody and the step became
    # "Already past `reviewed`?". What the step IS never changed: move the task
    # back and ask again.
    step = section[/^\d+\.\s+\*\*[^\n]*Move the task back and ask again.*?\z/m].to_s
    refute_empty step, "the gate never tells a stranded operator how to ask again"
    step[/```bash\n(.*?)```/m].to_s.lines.map(&:strip).grep(/\Abin\/task /)
  end

  def measure_matrix
    SCENARIOS.each_with_object({}) do |(name, spec), measured|
      _reqs, _out, err, status = run_task(%W[move #{SLUG} #{spec[:dest]}], **spec[:opts])

      # A crashed move must never be read as a quiet one.
      assert status.success?, "#{name}: bin/task move exited #{status.exitstatus}: #{err}"
      measured[name] = err.include?("DISCARDED") ? :warn : :silent
    end
  end

  # --- the stub board ---

  def sandbox_root
    @sandbox_root ||= Dir.mktmpdir("approval-drop-docs-sandbox")
  end

  # Shells out to the REAL bin/task against a localhost stub board. No Rails, no
  # network — the point is to drive the binary an agent actually runs.
  #
  #   devops:         what the pre-PATCH GET shows
  #   devops_after:   what the board serves AFTER the PATCH, replacing the above —
  #                   models a writer that moved the record inside this move's own
  #                   window, which the pre-read by construction could not predict
  #   fail_get:       the pre-read is UNREADABLE (the board hiccuped)
  #   stamps_receipt: whether the modelled settle writes approval_request_dropped_at
  #                   (false models a board too old to carry the receipt at all)
  def run_task(args, **board)
    with_stub_board(**board) { |run| return [@requests, *run.call(args)] }
  end

  # One stub board, any number of commands against it — so a two-step remedy is
  # judged on the state it leaves behind rather than on each command's exit code.
  def with_stub_board(stub_stage: "building", devops: { "kind" => "feature" },
                      fail_get: nil, stamps_receipt: true, devops_after: nil)
    @stub_devops = devops
    @persisted_stage = stub_stage
    @fail_get = fail_get
    @stub_stamps_drop_receipt = stamps_receipt
    @stub_devops_after = devops_after
    @requests = []

    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { serve(server, @requests) }

    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-docs-guard"
    }.merge(TaskUsageSandboxEnv.child_env(sandbox_root)))

    yield ->(args) { Open3.capture3(env, RbConfig.ruby, BIN, *args) }
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
      refusal = approval_request_stage_refusal(body, requested || @persisted_stage)
      return refusal if refusal

      @stub_devops = @stub_devops.merge(devops_of(body))
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

  # The board's settle rule, MODELLED: Task#settle_operator_approval_past_request_window
  # resolves a WAITING request to "none" on any save landing outside
  # APPROVAL_REQUEST_STAGES, and stamps approval_request_dropped_at as the receipt.
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

    @stub_devops["approval_request_dropped_at"] = STAMP
  end

  def stage_of(body) = parsed(body)["stage"]

  def devops_of(body) = parsed(body)["devops"].is_a?(Hash) ? parsed(body)["devops"] : {}

  def parsed(body)
    return {} if body.to_s.empty?

    JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  # Task.guard_approval_request_stage!, MODELLED: posting approval_status
  # "waiting" at a stage that cannot hold a request is REFUSED (422), because the
  # save would settle it to "none" and the board would never pulse. bin/task turns
  # any non-2xx into a die!, which is what makes the printed remedy order-sensitive.
  # The real constant is pinned by test/models/task_approval_request_guard_test.rb,
  # in a lane that has Rails; this file never boots the app.
  def approval_request_stage_refusal(body, stage)
    return nil unless devops_of(body)["approval_status"].to_s == "waiting"
    return nil if SETTLE_EXEMPT_STAGES.include?(stage)

    ["422 Unprocessable Entity",
     JSON.generate("error" => "devops.approval_status cannot be set to \"waiting\" at stage #{stage} — " \
                              "an approval request is only actionable in #{SETTLE_EXEMPT_STAGES.join(" or ")}")]
  end

  def task_response
    JSON.generate("data" => { "slug" => SLUG, "stage" => @persisted_stage, "merged" => "",
                              "release_slug" => nil, "metadata" => { "devops" => @stub_devops } })
  end
end

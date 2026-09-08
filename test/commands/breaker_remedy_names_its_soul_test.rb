# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"
require "shellwords"
require_relative "../support/session_env"

# EVERY `bin/task block` COMMAND bin/task PRINTS MUST NAME ITS ACTING SOUL — proven
# by RUNNING the printed command, not by reading it.
#
# ═══ THE DEFECT (/tasks/breaker-remedy-omits-agent) ═══
#
# When the two-bounce breaker trips, `bin/task block` refuses and prints TWO
# copy-pasteable recipes: the operator ESCALATION (`--kind dependency`) and, for a
# mechanical bounce, the BREAKER-ACK re-run (`--kind rework … --breaker-ack`).
# Neither carried `--agent`, and `bin/task` does not run a bare block as whoever
# pasted it. `resolved_block_actor` falls through the caller's unset session persona
# to `default_block_actor`, which returns a LITERAL "avi" for rework-on-submitted and
# NIL for every other kind. Measured 2026-09-08 by executing both recipes verbatim
# against a stub board:
#
#   RECIPE                                  PASTED BY THE REVIEWER IT WAS PRINTED FOR
#   --kind rework … --breaker-ack   exit 11, ZERO writes. The block resolves to "avi",
#                                   which grades FOREIGN against carl's own live claim.
#                                   The breaker hands the verdict owner a command the
#                                   verdict-owner gate then refuses him.
#   --kind rework … --breaker-ack   exit 0, and it WRITES
#     (no live review claim)        {"event":{"actor":"avi"},"by":"avi"} — a bounce
#                                   recorded against a soul that did nothing.
#   --kind dependency               exit 0, and it WRITES {"event":{"source":"cli"}} —
#     (the escalation)              no `actor`, no `by`. THE UNATTRIBUTED BLOCK. That
#                                   entry lands in the task's author set, and
#                                   `bin/reviewer-select` then REFUSES to pick, because
#                                   it cannot exclude a soul it cannot name. The
#                                   no-self-review property goes unverified for that
#                                   review, and a human hand-picks the light.
#
# So the remedy quietly disarms the guard that keeps a soul off its own PR.
#
# ═══ WHY THIS FILE EXECUTES THE RECIPES ═══
#
# `assert_match(/--agent/, printed)` is the obvious test and it is the wrong one. It
# passes on a recipe whose flag the parser rejects, on one whose soul never reaches
# the write, and on one printed in a shape no shell can run — all three of which look
# identical in a string. The sibling defect on PR #1283 was exactly that: a printed
# remedy carrying a flag that did not exist, caught only because the test RAN it.
#
# So phase 1 trips the breaker and captures what it printed; phase 2 hands those exact
# lines back to `bin/task` and reads the resulting board write. The load-bearing
# assertion is the WRITE — `by` and `event.actor` naming the reviewer — because a
# recipe can carry `--agent` and still not land it.
#
# THE EXTRACTION IS COUNTED. A scan is exit-blind: if the recipe matcher ever reads
# nothing, every per-recipe assertion below is skipped and this file passes having
# proved nothing. `RECIPE_COUNT` is what makes a green run mean something, and it is
# an equality on purpose — a THIRD recipe added later must arrive here and be given
# its execution proof, not inherit these two silently.
#
#   ruby -Itest test/commands/breaker_remedy_names_its_soul_test.rb
class BreakerRemedyNamesItsSoulTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SLUG = "probe-breaker-remedy"

  # The reviewer who OWNS the verdict — the only soul the breaker's recipes are ever
  # printed to, because the verdict-owner gate fires first and refuses everyone else.
  OWNER = "carl"
  OWNER_SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b"
  OWNER_NONCE = "holder01"

  # The escalation and the breaker-ack re-run. Both are printed by the same refusal.
  RECIPE_COUNT = 2

  # What a reviewer types in place of the elision the breaker prints for "the flags
  # you already passed". Substituting it is what pasting the recipe MEANS.
  ELISION = "..."
  ELISION_FILL = %(--summary "Mechanical bounce red CI" --feedback "CI is red on the head SHA.").freeze

  def test_integration_every_printed_block_recipe_records_the_reviewer_who_pasted_it
    printed = trip_the_breaker
    recipes = block_recipes(printed)

    assert_equal RECIPE_COUNT, recipes.size, <<~MSG
      extracted #{recipes.size} `bin/task block` recipe(s) from the breaker's refusal, expected #{RECIPE_COUNT}.

      #{printed}

      ZERO means the matcher went blind and every assertion below would be vacuous.
      MORE means a new recipe was added — give it its own execution proof here rather
      than widening this number.
    MSG

    recipes.each do |recipe|
      argv = runnable(recipe)
      writes = execute(argv)

      assert_equal 1, writes.size,
                   "pasting this recipe wrote #{writes.size} block(s), expected 1 — the reviewer it was " \
                   "printed for cannot run it:\n  #{recipe}"

      body = writes.first
      assert_equal OWNER, body["by"],
                   "the block landed as #{body["by"].inspect}, not #{OWNER.inspect} — a recipe printed to " \
                   "#{OWNER} must record #{OWNER}:\n  #{recipe}\n  wrote #{body.to_json}"
      assert_equal OWNER, body.dig("event", "actor"),
                   "the TaskEvent named #{body.dig("event", "actor").inspect}. An event with a session and no " \
                   "actor is the UNATTRIBUTED worker that makes bin/reviewer-select fail closed:\n  #{recipe}"
    end
  end

  # THE CONTROL. Without it, "the recipes all record #{OWNER}" and "the harness never
  # ran anything" are the same green. This is the pre-fix behaviour, planted by hand:
  # the identical block with `--agent` stripped, executed the same way, must NOT
  # record the reviewer. If this ever starts recording #{OWNER}, the defect has been
  # fixed somewhere else and the assertions above have stopped proving their point.
  def test_integration_the_same_block_without_agent_does_not_record_the_reviewer
    writes = execute(["block", SLUG, "--kind", "dependency",
                      "--summary", "Escalated reviewer builder disagree",
                      "--feedback", "builder says X, review says Y"])

    assert_equal 1, writes.size, "the control must reach the write — otherwise it proves nothing"
    refute_equal OWNER, writes.first["by"],
                 "a block with no --agent must NOT resolve to the caller's soul; if it does, " \
                 "resolved_block_actor changed and this whole file is testing a defect that no longer exists"
    assert_nil writes.first.dig("event", "actor"),
               "the un-agented dependency block is the UNATTRIBUTED one — that absence is the defect"
  end

  # ── phase 1: make the breaker print ─────────────────────────────────────────

  # Runs the block the OWNER would run, against a ledger holding one prior send-back,
  # and returns everything the refusal printed. `--agent OWNER` is passed because the
  # verdict-owner gate fires BEFORE the breaker: without it the run is refused as a
  # non-owner (exit 11) and the recipes are never printed at all.
  def trip_the_breaker
    _writes, err, status = run_task(
      ["block", SLUG, "--kind", "rework", "--summary", "Probe send back now",
       "--feedback", "probe feedback", "--agent", OWNER],
      bounces: 1
    )

    assert_equal 10, status.exitstatus,
                 "expected the breaker's TRIPPED refusal (exit 10); got #{status.exitstatus}:\n#{err}"
    err
  end

  # Every `bin/task block …` invocation in the printed refusal, with backslash
  # continuations joined back into one line. Anchored on the invocation itself rather
  # than on indentation, so a reflowed message does not silently empty the scan.
  def block_recipes(text)
    joined = text.gsub(/\\\n\s*/, " ")
    joined.lines.map(&:strip).select { |line| line.start_with?("bin/task block") }
  end

  # ── phase 2: run what was printed ───────────────────────────────────────────

  # The printed recipe as argv. Only the elision is substituted — that is the one
  # token that stands for something the reviewer supplies. Everything else, including
  # the `--agent` under test, is executed exactly as printed.
  def runnable(recipe)
    filled = recipe.sub(/(?<=\s)#{Regexp.escape(ELISION)}(?=\s)/, ELISION_FILL)
    refute_includes filled, ELISION, "the elision must be substituted before the recipe can run: #{recipe}"

    argv = Shellwords.split(filled)
    assert_equal ["bin/task", "block", SLUG], argv.first(3),
                 "the recipe is not the invocation this test thinks it is: #{recipe}"
    argv.drop(1)
  end

  # ── the board ───────────────────────────────────────────────────────────────

  # Drives the REAL bin/task against a stub board and returns [writes, stderr, status].
  # `writes` is only the block PATCH — the auth POST happens on every run, refused or
  # not, so counting it would make "nothing was written" unfalsifiable.
  #
  # The child env goes through BOTH sandboxes: SessionEnv.neutralized scrubs the
  # operator's ambient session before this run opts in to a fake one, and
  # TaskUsageSandboxEnv.child_env pins the usage store, transcript root and HOME into
  # a tmpdir. TASK_SKIP_MARKER stops the run repointing the operator's active-feature
  # marker at this fixture slug.
  def run_task(args, bounces: 1)
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => OWNER_SESSION, "TASK_CLAIM_NONCE" => OWNER_NONCE
        )
      )

      with_board_sink(writes, bounces: bounces) do |base|
        _out, err, status = Open3.capture3(env.merge("TASK_API_BASE" => base), BIN, *args)
      end

      return [writes.filter_map { |w| JSON.parse(w) rescue nil }, err, status]
    end
  end

  def execute(argv)
    writes, err, status = run_task(argv, bounces: 1)
    assert status, "the child never ran: #{err}"
    writes
  end

  # A live review claim held by OWNER, so the verdict-owner gate admits OWNER and
  # refuses the literal "avi" the bare recipes resolve to.
  def holder
    { "task_slug" => SLUG, "session" => OWNER_SESSION, "agent" => OWNER, "label" => "carl",
      "expires_at" => (Time.now + 90).utc.iso8601, "heartbeat_age" => 3, "live" => true }
  end

  def with_board_sink(writes, bounces:)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        verb, path = request.split(/\s+/).first(2).map(&:to_s)
        writes << payload if payload && verb == "PATCH" && path.include?("/block")

        body = respond(path, bounces)
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

  # ROUTING BY PATH MATTERS: a sink answering everything with one body answers /auth
  # with a task, bin/task dies on the missing "token", and that reads as a refusal.
  def respond(path, bounces)
    case path
    when %r{/api/v1/auth}       then { token: "sink-bearer" }.to_json
    when %r{/review_claim}      then { data: { holder: holder } }.to_json
    when %r{/api/v1/activities} then ledger_body(bounces)
    when %r{/block}             then { data: { slug: SLUG, stage: "building" } }.to_json
    else task_body
    end
  end

  # `n` countable send-backs. ONE is enough to trip (Verdict#tripped? is
  # `count.positive?`), and the kind must be stamped in metadata or the row grades
  # `unknown` — which still counts, but for a different reason than the one under test.
  def ledger_body(n)
    rows = Array.new(n) do |i|
      { "created_at" => (Time.now - (60 * (i + 1))).utc.iso8601, "agent_slug" => OWNER,
        "description" => "prior send-back",
        "metadata" => { "kind" => "rework", "summary" => "Prior send back here" } }
    end
    { data: rows, meta: { total: rows.size } }.to_json
  end

  # `stage: submitted` is load-bearing: it is the exact state in which
  # `default_block_actor` returns the literal "avi", which is the fallthrough that
  # makes a bare rework recipe refuse its own reviewer.
  def task_body
    { data: { slug: SLUG, stage: "submitted", title: "Probe Breaker Remedy",
              metadata: { devops: { kind: "bug", repositories: ["mcritchie-studio"],
                                    worktree_slug: SLUG } } } }.to_json
  end
end

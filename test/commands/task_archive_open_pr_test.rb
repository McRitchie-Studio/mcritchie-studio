require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "json"
require "time"
require "fileutils"
require_relative "../../lib/open_pr_guard"

# The ARCHIVE open-PR gate REFUSES. It does not warn and carry on.
#
# THE MEASURED CASE THIS EXISTS TO CATCH (2026-09-01, found by auditing the open-PR
# backlog). studio-engine #245 was opened 2026-08-31 against `accepted` carrying 169
# lines of new tests. Its task `move-web3-modals-to-solana` was ARCHIVED on
# 2026-09-01 at 03:12Z, and the blocker written into the PR's own body — "merge AFTER
# solana-studio#9" — was DISCHARGED when that PR merged later the same day. The work
# became mergeable in principle a day after its task was archived, with nobody
# watching either side, and it surfaced a MONTH later only because a human asked for
# a backlog audit.
#
# `bin/task move <slug> archived` ran the stage move without ever asking whether the
# task still had an open PR. The holder gate that shipped the day before asks a
# DIFFERENT question — whether a live session's UNCOMMITTED work is at risk — and by
# design says nothing about durable artifacts. Neither half covered this.
#
# THE ASSERTION THAT SEPARATES A GATE FROM A WARNING IS "NO WRITE". A path that
# printed the whole refusal and archived anyway would pass every message assertion
# below; the only thing it does that a refusing gate never does is send the PATCH. So
# the refusal is pinned on the ABSENCE of the board write, and the messages are
# pinned separately as the evidence the operator decides close-vs-revive with.
class TaskArchiveOpenPrTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze
  MOVER_SESSION = "019f4c1d-7b2e-74a2-8f19-2c7d90ab3311".freeze
  MOVER_NONCE   = "mover001".freeze

  ENGINE_PR = "https://github.com/McRitchie-Studio/studio-engine/pull/245".freeze
  SOLANA_PR = "https://github.com/McRitchie-Studio/solana-studio/pull/9".freeze

  # A record the HOLDER gate lets straight through — no session, no mascot, no claim,
  # no desk. `ArchiveHolderGuard.decide` grades it `:unheld` and permits it. That
  # isolation is deliberate: every refusal below is then attributable to the open-PR
  # gate alone, and a test that accidentally tripped the holder gate would prove
  # nothing about this one.
  UNHELD = { kind: "bug", repositories: ["studio-engine", "solana-studio"] }.freeze

  # ── THE REFUSAL ─────────────────────────────────────────────────────────────

  test "[integration] archiving a task whose PR is still OPEN exits 1" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" })

    assert_equal 1, result[:status].exitstatus,
                 "before this fix the archive ran without ever asking, and exited 0"
  end

  # THE LOAD-BEARING ONE. Everything else here is also true of a path that only warns.
  test "[integration] the refused archive sends NO write to the board" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" })

    assert_empty result[:writes],
                 "a PATCH here means the task WAS archived, leaving the PR open and unwatched — " \
                 "which is the whole defect, not a louder version of it"
  end

  test "[integration] the refusal names the open PR, its state, and its url" do
    err = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" })[:err]

    assert_includes err, "OPEN", "the refusal must say what state it is refusing on"
    assert_includes err, "studio-engine#245",
                      "and name the PR — a refusal the operator cannot act on is a dead end"
    assert_includes err, ENGINE_PR, "with the url they will actually click"
  end

  test "[integration] the refusal offers a pasteable override and the resolve-it path" do
    err = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" })[:err]

    assert_includes err, "bin/task move #{SLUG} archived --force",
                      "--force is the human decision seam; a refusal with no way forward is a wedge"
    assert_includes err, "gh pr close",
                      "and the refusal must offer the RESOLVE path too, or it teaches --force as " \
                      "the only move — closing the PR deliberately is usually the right answer"
  end

  # ── THE MULTI-REPO TRAP ─────────────────────────────────────────────────────
  #
  # THE ONE THAT MAKES A NAIVE FIX MISS. `devops.pr_url` holds exactly ONE url, so a
  # task naming two repos records its second repo's PR only in `devops.pr_urls`. Here
  # the SINGULAR names the MERGED repo and the MAP holds the OPEN one — a gate reading
  # only `pr_url` sees "merged" and archives clean.
  #
  # (The live `move-web3-modals-to-solana` record happens to carry them the other way
  # round: its `pr_url` is the OPEN studio-engine #245 and its map holds both. This
  # fixture is deliberately the INVERSE, because that ordering is the one a
  # singular-only check survives, and both orderings occur.)

  test "[integration] an open PR reachable ONLY through devops.pr_urls still refuses" do
    devops = UNHELD.merge(
      pr_url: SOLANA_PR,
      pr_urls: { "solana-studio" => SOLANA_PR, "studio-engine" => ENGINE_PR }
    )
    result = archive(devops: devops, states: { SOLANA_PR => "MERGED", ENGINE_PR => "OPEN" })

    assert_equal 1, result[:status].exitstatus,
                 "the singular says MERGED and is not the whole set; reading only devops.pr_url " \
                 "is exactly how the measured case would have passed clean"
    assert_empty result[:writes]
    assert_includes result[:err], "studio-engine#245"
  end

  test "[integration] the refusal names the MERGED sibling too, not only the open one" do
    devops = UNHELD.merge(pr_url: SOLANA_PR,
                          pr_urls: { "solana-studio" => SOLANA_PR, "studio-engine" => ENGINE_PR })
    err = archive(devops: devops, states: { SOLANA_PR => "MERGED", ENGINE_PR => "OPEN" })[:err]

    assert_includes err, "solana-studio#9",
                      "close-vs-revive is decided against the WHOLE set: on the real record it is " \
                      "the merged sibling that proves the open PR's stated blocker is discharged"
  end

  # ── THE GATE MUST ALSO OPEN ─────────────────────────────────────────────────
  #
  # A suite that only proved the refusal would pass against a gate that refuses
  # UNCONDITIONALLY — and lib/archive_holder_guard.rb has the measurement for what
  # that costs: its first cut refused 31 of 34 live tasks, after which --force is
  # muscle memory and the gate protects nothing.

  test "[integration] a task whose PRs all merged archives silently" do
    devops = UNHELD.merge(pr_url: SOLANA_PR, pr_urls: { "solana-studio" => SOLANA_PR })
    result = archive(devops: devops, states: { SOLANA_PR => "MERGED" })

    assert_equal 0, result[:status].exitstatus, "there is nothing unresolved to protect"
    refute_empty result[:writes]
    assert_equal "archived", result[:writes].last["stage"]
  end

  test "[integration] a task with no PR at all archives" do
    result = archive(devops: UNHELD, states: {})

    assert_equal 0, result[:status].exitstatus,
                 "a gate that refused an idea nobody ever opened a PR for would refuse most of " \
                 "the board, and Alex's clean-up archives exactly that population"
    refute_empty result[:writes]
  end

  test "[integration] a CLOSED PR archives — it is already resolved" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "CLOSED" })

    assert_equal 0, result[:status].exitstatus
    refute_empty result[:writes]
  end

  test "[integration] a non-archive move is not subject to the open-PR gate" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" },
                     stage: "submitted", to: "reviewed")

    assert_equal 0, result[:status].exitstatus,
                 "every task in review has an open PR BY DEFINITION — gating the whole ladder " \
                 "on this would stall every review handoff there is"
    refute_empty result[:writes]
  end

  # ── THE UNREADABLE STATE MUST NOT LIE ───────────────────────────────────────
  #
  # The GitHub App installation token expires ABOUT HOURLY BY DESIGN, so an
  # unreadable `gh` is the routine state on this machine. Refusing on it would refuse
  # most archives on most days, which is the documented way this class of gate dies.
  # So it warns — and the warning must not borrow the refusal's confidence.

  test "[integration] a PR whose state cannot be read archives with a warning" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => :fail })

    assert_equal 0, result[:status].exitstatus,
                 "the token expires hourly by design; a gate that refused on every unreadable " \
                 "PR would be --force'd past until it protected nothing"
    refute_empty result[:writes]
  end

  test "[integration] the unreadable warning says the check failed, NOT that the PR is open" do
    err = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => :fail })[:err]

    assert_includes err, "could not read", "it must name what it failed to establish"
    assert_includes err, "gh-auth-refresh", "and how to fix it — the usual cause is a stale token"
    assert_includes err, "orphan-prs",
                      "and where the orphan it just let through will still be findable"
    refute_includes err, "REFUSING",
                      "a check that did not complete has established nothing. Claiming the PR is " \
                      "open would be the confident lie that costs the guard its credibility"
  end

  # ── --force RECORDS THE DECISION ────────────────────────────────────────────

  test "[integration] --force archives and RECORDS the abandonment on the task" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" },
                     flags: ["--force"])

    assert_equal 0, result[:status].exitstatus, "--force must let the archive through"
    patch = result[:writes].last
    assert_equal "archived", patch["stage"]

    recorded = patch.dig("devops", "abandoned_prs")
    assert_kind_of Array, recorded,
                   "the whole point of the override is that a later reader can tell the PR was " \
                   "dropped DELIBERATELY rather than forgotten — an unrecorded --force is " \
                   "indistinguishable from the bug"
    assert(recorded.any? { |entry| entry.include?(ENGINE_PR) },
           "the record must name the PR that was abandoned: #{recorded.inspect}")
  end

  test "[integration] --force names the open PR it is overriding" do
    err = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" },
                  flags: ["--force"])[:err]

    assert_includes err, "--force",
                      "an override that prints nothing turns the gate into a speed bump nobody " \
                      "remembers clearing"
    assert_includes err, "studio-engine#245"
  end

  # THE 422 REGRESSION. The obvious implementation echoes the task's whole stored
  # devops back (belt-and-braces read-merge-write, which is what the `move building`
  # claim path does). It BREAKS HERE. Measured 2026-09-02 against the live board: 156 of
  # 1,586 tasks carry `block_kind` or `release_train` INSIDE metadata.devops — legacy
  # rows from before those names moved to columns — and both are
  # Task::DEVOPS_COLUMN_KEYS, so normalize_devops_metadata RAISES and both controllers
  # turn that into a 422.
  #
  # All 156 are already `archived`, which this gate skips, so the failure needs the task
  # REVIVED first — and `archived` is not a lock. Narrow, but it lands right after an
  # operator deliberately chose to abandon a PR, destroying the receipt this path writes.
  #
  # The board merges a devops PATCH onto what is stored, so sending one key is both
  # sufficient and the only safe option.
  test "[integration] --force sends ONLY the key it owns, never a column-backed name" do
    devops = UNHELD.merge(pr_url: ENGINE_PR, worktree_slug: "probe-desk", branch: "feat/probe",
                          block_kind: "rework")
    result = archive(devops: devops, states: { ENGINE_PR => "OPEN" }, flags: ["--force"])

    written = result[:writes].last["devops"]
    assert_equal [OpenPrGuard::RECORD_KEY], written.keys,
                 "echoing the stored devops back 422s on any task carrying block_kind or " \
                 "release_train — 157 of them on the live board. Preserving the rest is the " \
                 "SERVER's job (Task.merge_devops_into_metadata), not this CLI's"
  end

  # `merged_record` has to be wired, not just unit-tested. A task can be archived,
  # revived and archived again, and the earlier decision is still why the earlier PR
  # was dropped.
  test "[integration] --force appends to an abandonment already on the task" do
    devops = UNHELD.merge(pr_url: ENGINE_PR, abandoned_prs: ["an-older-abandonment"])
    result = archive(devops: devops, states: { ENGINE_PR => "OPEN" }, flags: ["--force"])

    recorded = result[:writes].last.dig("devops", OpenPrGuard::RECORD_KEY)
    assert_includes recorded, "an-older-abandonment", "a later archive must not erase the earlier one"
    assert(recorded.any? { |entry| entry.include?(ENGINE_PR) }, "and must add the new one")
  end

  # THE SILENT-EVAPORATION REGRESSION. `abandoned_prs` has to be a storable name in
  # Task::DEVOPS_LIST_KEYS; `normalize_devops_metadata` drops anything outside
  # DEVOPS_KEYS and the caller still gets a 200. That is precisely how `agent_slug`
  # sat dead inside ArchiveHolderGuard::PAINT_KEYS for a whole review — a key list
  # nobody can populate is a promise the gate cannot keep. So the CLI reads the
  # record BACK, and a board that drops it must fail LOUDLY rather than report a
  # recorded abandonment that does not exist.
  test "[integration] a board that silently drops the record fails loudly" do
    result = archive(devops: UNHELD.merge(pr_url: ENGINE_PR), states: { ENGINE_PR => "OPEN" },
                     flags: ["--force"], drop_record: true)

    refute_equal 0, result[:status].exitstatus,
                 "a 200 for a write that reached nothing is the failure this read-back exists " \
                 "to make impossible"
    assert_includes result[:err], "abandoned_prs"
  end

  # `abandoned_prs` must actually BE storable — the assertion above proves the CLI
  # notices a drop, this one proves the model would not drop it in the first place.
  # Pinned on the real predicate (the model's own key list), never on a copy of it.
  test "[unit] abandoned_prs is a storable devops key" do
    assert_includes Task::DEVOPS_KEYS, OpenPrGuard::RECORD_KEY,
                    "a record the normalizer drops is a promise the gate cannot keep"
    assert_includes Task::DEVOPS_LIST_KEYS, OpenPrGuard::RECORD_KEY,
                    "it holds one entry per abandoned PR, so it must normalize as a LIST"
  end

  private

  # Run the real `bin/task move <slug> <to>` against a board serving a task with the
  # given devops and a `gh` stubbed to report the given PR states, returning the exit
  # status, stderr, and every write the CLI sent.
  #
  # `states` maps a PR url to the GitHub state string the stub reports, or `:fail` to
  # make `gh` exit non-zero (the stale-token case). A url with no entry also fails,
  # so a test cannot accidentally assert against a state it never set up.
  #
  # The child env goes through BOTH sandboxes for the reason task_archive_gate_test.rb
  # documents: the suite arms TASK_USAGE_SANDBOX process-wide, so an unpinned child
  # aborts before it ever reaches the gate — producing exit 1 and an empty write log
  # from a completely different refusal, which would make the two assertions this file
  # turns on pass for the wrong reason.
  def archive(devops:, states:, stage: "designed", to: "archived", flags: [], drop_record: false)
    Dir.mktmpdir do |dir|
      writes = []
      err = status = nil
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
          "CLAUDE_CODE_SESSION_ID" => MOVER_SESSION, "TASK_CLAIM_NONCE" => MOVER_NONCE,
          "CLAUDE_PROJECTS_DIR" => dir,
          "PATH" => "#{stub_gh(dir, states)}:#{ENV.fetch('PATH')}"
        )
      )

      with_board_sink(writes, stage: stage, to: to, devops: devops, drop_record: drop_record) do |base|
        _out, err, status = Open3.capture3(env.merge("TASK_API_BASE" => base),
                                           BIN, "move", SLUG, to, *flags)
      end

      { status: status, err: err, writes: writes.filter_map { |w| JSON.parse(w) rescue nil } }
    end
  end

  # A `gh` on PATH that answers `pr view` from a fixed table. Stubbing the BINARY
  # rather than injecting a seam keeps the real shell-out — argument order, JSON
  # parsing, non-zero exits — inside the test's reach.
  def stub_gh(dir, states)
    bin = File.join(dir, "stub-bin")
    FileUtils.mkdir_p(bin)
    table = states.to_h { |url, state| [OpenPrGuard.ref_for(url).values_at(:repo, :number).join("#"), state.to_s] }
    path = File.join(bin, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      table = JSON.parse(#{table.to_json.dump})
      args = ARGV
      exit 1 unless args[0] == "pr" && args[1] == "view"
      number = args[2]
      repo = args[args.index("--repo") + 1] if args.include?("--repo")
      state = table["\#{repo}#\#{number}"]
      # No entry, or an explicit :fail, is the stale-token case: non-zero and silent.
      if state.nil? || state == "fail"
        warn "gh: could not resolve"
        exit 1
      end
      puts JSON.generate({ "state" => state, "baseRefName" => "accepted" })
    RUBY
    FileUtils.chmod(0o755, path)
    bin
  end

  # A board answering the calls `move` makes: the bearer exchange, the task read the
  # gates judge, and — only if they let it through — the PATCH.
  #
  # IT ECHOES BACK WHAT IT WAS PATCHED WITH, because the CLI reads the task back and
  # verifies both the stage move and the abandonment record persisted. A sink that
  # served the original devops forever would fail that read-back on every permitted
  # run for a reason that has nothing to do with the gate. `drop_record: true` is the
  # forgetful board — a 200 for a write that reached nothing.
  def with_board_sink(writes, stage:, to:, devops:, drop_record: false)
    server = TCPServer.new("127.0.0.1", 0)
    auth = { token: "sink-bearer" }.to_json
    moved = false
    served = devops.transform_keys(&:to_s)
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
          patched = (JSON.parse(payload)["devops"] rescue nil)
          if patched.is_a?(Hash)
            merged = served.merge(patched)
            merged.delete(OpenPrGuard::RECORD_KEY) if drop_record
            served = merged
          end
        end
        body =
          if request.include?("/api/v1/auth")
            auth
          else
            task_body(moved ? to : stage, served)
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
  # bug in exactly the way the holder gate's first suite was: nine integration tests
  # passed there against a gate refusing 31 of 34 real tasks, because `task_body`
  # omitted two fields Api::V1::TasksController always sends.
  #
  # So this one carries them BOTH — `holder_liveness_seconds_ago` and
  # `holder_gate_in_flight`, fresh, as the board reports for any task just triaged —
  # AND the PR fields this gate reads, `metadata.devops.pr_url` and
  # `metadata.devops.pr_urls`, which is the shape `bin/task show
  # move-web3-modals-to-solana --json` returns for the live record.
  def task_body(stage, devops, liveness: 12)
    { data: { slug: SLUG, stage: stage, title: "Probe Task",
              holder_liveness_seconds_ago: liveness, progress_seconds_ago: liveness,
              holder_gate_in_flight: false, gate_in_flight: false,
              metadata: { devops: devops } } }.to_json
  end
end

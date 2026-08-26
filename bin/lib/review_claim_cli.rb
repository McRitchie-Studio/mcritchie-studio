#!/usr/bin/env ruby
# frozen_string_literal: true

# ReviewClaimCli — the per-TASK REVIEW CLAIM cli, backing `bin/task review-claim`.
# It lets MANY pr-review sessions run in parallel: each acquires the ONE task it
# picked (from GET /api/v1/tasks?stage=submitted&reviewable=1), and any session that
# finds a task already under LIVE review simply SKIPS it. This is the mirror of
# bin/devops-shift's ROLE lease one granularity down (lane → task), reusing the very
# same live-instance identity + TTL + detached-renewer machinery.
#
#   bin/task review-claim acquire <slug> [--label <text>] [--agent <soul>]  # take it, or skip
#   bin/task claim-next-review    [--label <text>] [--agent <soul>]  # ATOMIC server pop: claim the
#                                                            # next reviewable GREEN-CI task
#   bin/task review-claim renew   <slug>                     # one heartbeat (internal)
#   bin/task review-claim release <slug>                     # clean drop when the review lands
#   bin/task review-claim status  <slug>                     # who (if anyone) is reviewing it
#   bin/task review-claim renew-loop <slug> --anchor-pid <p> --anchor-start <s>  # internal
#   bin/task claim-next-review --help | -h                   # usage; claims NOTHING
#
# EVERY ARGUMENT IS ACCOUNTED FOR BEFORE ANYTHING IS CLAIMED. --help/-h anywhere on
# the line prints usage and mutates nothing; an unrecognized flag, a single-dash
# token, or a positional the subcommand does not take REFUSES (exit 1) instead of
# running the side effect. This is a scar: `claim-next-review --help` once dropped
# the flag and popped a REAL task, taking a live review lease on work nobody was
# reviewing. The command whose whole purpose is a side effect is the one an agent
# probes with --help first, so refusal, not silence, is the only safe default.
#
# `claim-next-review` is the server-authoritative sibling of `acquire`: instead of the
# caller naming a task it picked, the BOARD selects the highest-ranked reviewable task
# with green CI and claims it in one transaction. It anchors a renewer just like
# `acquire`, and prints the claimed slug to stdout (exit 0) or "none" (exit 4).
#
# Identity is the SAME live-instance identity the build claim and the shift lease use
# (session id + per-process nonce, SessionIdentity), so the renewer renews the right
# review. RENEWAL IS OWNED BY THE RUN, NOT BY THE UI: `acquire` starts a detached
# renewer (reusing bin/lib/shift_renewer.rb) anchored to the agent process, and
# `release` stops it — so a headless pr-review supervisor holds its task for the
# review's whole life, and a crashed one frees it within a TTL.
#
# EXIT CODES make the acquire gate scriptable (and the SOP branch on it):
#   0  — acquired (you hold the review; proceed to review this task)
#   10 — skipped (a DIFFERENT live instance is already reviewing it; pick another)
#   4  — none (claim-next-review only): the atomic pop found NOTHING eligible (no
#        reviewable task, or none with green CI) — a normal empty pop, not a failure.
#   1  — could not run (no session id / no board / usage error) — fail OPEN so a
#        telemetry hiccup never wedges a real review.
# Best-effort and never raises; renew/release/status always exit 0.

require "json"
require "fileutils"
require "rbconfig"
require_relative "agent_api"
require_relative "session_identity"
require_relative "session_markers"
require_relative "shift_renewer"

class ReviewClaimCli
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  # Acquire exit codes (see header).
  OK = 0
  SKIPPED = 10
  CANT_RUN = 1
  # `claim-next` outcome: the atomic server pop found NOTHING eligible (no reviewable
  # task, or none green-CI) — a normal empty pop, not a failure, but nonzero so a
  # caller can branch (`slug=$(bin/task claim-next-review) || idle`).
  NONE = 4

  # --help/-h from ANY position prints usage and mutates nothing. Same two spellings
  # bin/task's HELP_FLAGS honors, because an agent probing this CLI has no way to
  # know it is a different parser.
  HELP_FLAGS = %w[--help -h].freeze

  # The flags each subcommand understands — the dictionary an unrecognized argument
  # is rejected against, the mirror of bin/task's PARSE_FLAG_NAMES + unknown_flag!.
  # A command with NO flags is still keyed here, so this hash doubles as the set of
  # subcommands run() dispatches; a key without a `when` arm below is drift, and a
  # test pins the two together.
  COMMAND_FLAGS = {
    "acquire"    => %w[--label --agent],
    "claim-next" => %w[--label --agent],
    "renew"      => [],
    "renew-loop" => %w[--anchor-pid --anchor-start],
    "release"    => [],
    "status"     => []
  }.freeze

  # The subcommands that name their own task. `claim-next` deliberately does NOT:
  # the BOARD picks the task, so a slug on that line is a caller who meant
  # `acquire` — and popping a DIFFERENT task than the one they typed is the same
  # defect as the dropped flag, one seam over.
  SLUG_COMMANDS = %w[acquire renew renew-loop release status].freeze

  def initialize(env: ENV, out: $stdout, err: $stderr)
    @env = env
    @out = out
    @err = err
    @api = AgentApi.new(env: env, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
    # Injected in tests so no test ever forks a real renewer or signals a real pid.
    @spawner = method(:spawn_detached)
    @killer  = method(:terminate)
  end

  # Entry point. Returns the process exit code.
  #
  # ARGUMENT VALIDATION RUNS BEFORE DISPATCH, and that ordering is the whole point:
  # `bin/task claim-next-review --help` used to CLAIM A REAL TASK. The unrecognized
  # flag fell through parse_flags into an ignored key, the atomic pop ran anyway, and
  # a help probe took a live review lease on a task nobody was reviewing — filling
  # that task's crew seat with a reviewer that did not exist, undone by hand with
  # `review-claim release <slug>` (hit 2026-08-20). claim-next is the one review
  # command whose ENTIRE purpose is a side effect, and it is the first command an
  # agent reaches for in an unfamiliar lane — exactly when it probes --help. So help
  # prints usage and mutates NOTHING, and an argument this CLI cannot account for
  # REFUSES rather than assuming the rest of the line was what you meant.
  def run(argv)
    return usage(OK) if argv.any? { |arg| HELP_FLAGS.include?(arg) }

    command = argv.shift
    return usage(CANT_RUN) unless COMMAND_FLAGS.key?(command)

    bad = bad_arguments(command, argv)
    return refuse(command, bad) if bad.any?

    slug = positionals(argv).first
    flags = parse_flags(argv)

    case command
    when "acquire"    then acquire(slug, flags)
    when "claim-next" then claim_next(flags)
    when "renew"      then renew(slug)
    when "renew-loop" then renew_loop(slug, flags)
    when "release"    then release(slug)
    when "status"     then status(slug)
    else usage(CANT_RUN) # drift guard: a COMMAND_FLAGS key with no arm here
    end
  rescue StandardError => e
    @err.puts("review-claim failed (ignored): #{e.class}: #{e.message}")
    CANT_RUN
  end

  # ── Commands ────────────────────────────────────────────────────────────────

  def acquire(slug, flags)
    return usage_slug("acquire") unless present?(slug)

    sid = session_id
    return cant_run("no session id — cannot identify this review") unless present?(sid)

    label = flags["label"].to_s.strip
    label = session_mascot(sid) if label.empty?
    # The reviewing SOUL — what the board paints in the crew seat. Explicit --agent
    # wins; otherwise the session's acting agent (the reviewer subagent narrates as
    # itself), else nothing and the seat waits for reviewer-select as before.
    reviewer = flags["agent"].to_s.strip
    reviewer = acting_agent(sid).to_s.strip if reviewer.empty?
    res = post("#{base(slug)}/review_claim",
               { "session" => sid, "nonce" => nonce, "label" => label, "reviewer" => reviewer })
    return cant_run("no response from the board — proceeding without a review claim") unless ok?(res)

    data = parse_data(res)
    if data["acquired"]
      write_marker(sid, slug)
      start_renewer(sid, slug)
      @out.puts("review-claim: ✅ #{slug} review claimed — this task is yours to review.")
      OK
    else
      report_skip(slug, data["holder"] || {}, data["disposition"].to_s)
      SKIPPED
    end
  end

  # `bin/task claim-next-review` — the ATOMIC server pop. Asks the board for the
  # highest-ranked reviewable GREEN-CI task and claims it in ONE request (the server
  # does reviewable + rank + green-CI filter + acquire in one transaction), then
  # anchors a renewer so the claim follows this RUN exactly like `acquire`. Prints the
  # claimed slug to stdout (exit 0), so a caller can `slug=$(bin/task claim-next-review)`,
  # or "none" (exit NONE) when nothing is eligible. Fail-open on no session / no board.
  def claim_next(flags)
    sid = session_id
    return cant_run("no session id — cannot identify this review") unless present?(sid)

    label = flags["label"].to_s.strip
    label = session_mascot(sid) if label.empty?
    reviewer = flags["agent"].to_s.strip
    reviewer = acting_agent(sid).to_s.strip if reviewer.empty?
    res = post("/api/v1/tasks/claim_next_review",
               { "session" => sid, "nonce" => nonce, "label" => label, "reviewer" => reviewer })
    return cant_run("no response from the board — could not claim a review") unless ok?(res)

    data = parse_data(res)
    claimed = data["claimed"]
    slug = claimed.is_a?(Hash) ? claimed["slug"].to_s : ""
    if present?(slug)
      write_marker(sid, slug)
      start_renewer(sid, slug)
      @out.puts(slug) # JUST the slug, so `slug=$(bin/task claim-next-review)` captures it
      OK
    else
      reason = data["reason"].to_s
      @err.puts("claim-next-review: nothing eligible to review#{reason.empty? ? '' : " (#{reason})"}.")
      report_blind_repos(data["blind_repos"])
      report_skipped_ci(data["skipped_ci"]) if reason == "no_green_ci"
      @out.puts("none")
      NONE
    end
  end

  def renew(slug)
    return usage_slug("renew") unless present?(slug)

    sid = session_id
    return OK unless present?(sid) # best-effort heartbeat — never a failure

    post("#{base(slug)}/review_claim/renew", { "session" => sid, "nonce" => nonce })
    OK
  end

  # The detached renewer body (started by `acquire`; not for hand invocation). Renews
  # while the anchor process lives, so the review lease follows the RUN and not the
  # UI. It inherits TASK_REVIEW_CLAIM_SESSION + TASK_CLAIM_NONCE from its parent
  # because, once detached, it can no longer re-derive the live-instance identity by
  # walking its own ancestry — a renewer that guessed its nonce would renew NOTHING,
  # and every renew would 204 silently, which is indistinguishable from the bug it
  # exists to fix.
  def renew_loop(slug, flags)
    return usage_slug("renew-loop") unless present?(slug)

    pid = flags["anchor-pid"]
    start = flags["anchor-start"]
    ShiftRenewer.run(
      alive:   -> { SessionIdentity.process_alive?(pid, start) },
      renew:   -> { renewed?(slug) },
      sleeper: ->(seconds) { sleep(seconds) },
      clock:   -> { Time.now },
      interval: ShiftRenewer.interval_from(@env["TASK_REVIEW_CLAIM_RENEW_INTERVAL"])
    )
    OK
  end

  def release(slug)
    return usage_slug("release") unless present?(slug)

    sid = session_id
    res = (post("#{base(slug)}/review_claim/release", { "session" => sid, "nonce" => nonce }) if present?(sid))
    stop_renewer(sid, slug)
    clear_marker(sid, slug)
    report_release(slug, res)
    OK
  end

  def status(slug)
    return usage_slug("status") unless present?(slug)

    res = get("#{base(slug)}/review_claim")
    return cant_run("could not read review status") unless ok?(res)

    holder = parse_data(res)["holder"]
    if holder.is_a?(Hash) && holder["live"]
      @out.puts("review-claim: #{slug} is under review — #{holder_line(holder)}")
    else
      @out.puts("review-claim: #{slug} is not under review — free to claim.")
    end
    OK
  end

  # ── The detached renewer ─────────────────────────────────────────────────────

  # Start a renewer for the review we just took. No anchor process ⇒ no renewer: we
  # will not start a background process whose owner we cannot identify, because
  # nothing would ever tell it to stop. That case (a plain shell, CI) simply keeps
  # the old status-line/manual renewal, and we say so rather than implying cover we
  # are not providing.
  def start_renewer(sid, slug)
    anchor = anchor_process
    unless anchor
      @out.puts("review-claim: note — no agent process to anchor a renewer to; " \
                "this review lapses in ~#{lease_ttl_seconds}s unless something renews it.")
      return nil
    end

    argv = [RbConfig.ruby, __FILE__, "renew-loop", slug,
            "--anchor-pid", anchor[:pid].to_s, "--anchor-start", anchor[:start].to_s]
    pid = @spawner.call(renewer_env(sid), argv)
    write_renewer_marker(sid, slug, pid) if pid
    pid
  rescue StandardError => e
    @err.puts("review-claim: could not start the review renewer (#{e.class}) — " \
              "the lease will rely on the status line as before.")
    nil
  end

  # The identity the renewer must carry. Detached, it cannot walk its way back to the
  # agent process, so both halves of the live-instance identity are handed down
  # explicitly — the nonce especially, since a wrong one renews nothing, silently.
  def renewer_env(sid)
    { "TASK_REVIEW_CLAIM_SESSION" => sid.to_s, "TASK_CLAIM_NONCE" => nonce.to_s }
  end

  # The process to anchor the lease lifetime to. TASK_REVIEW_CLAIM_ANCHOR_PID lets a
  # headless runner (or a test) name its own long-lived owner instead of relying on a
  # `claude`/`codex` ancestor being present.
  def anchor_process
    override = @env["TASK_REVIEW_CLAIM_ANCHOR_PID"].to_s.strip
    return { pid: override.to_i, start: SessionIdentity.proc_start(override) } unless override.empty?

    SessionIdentity.agent_process
  end

  # One heartbeat from inside the loop. TRUE keeps the loop running. A definitive 204
  # means the board says we are no longer the holder — released elsewhere, or the
  # review changed hands — so we stop. An unreachable board is NOT that: a network
  # blip keeps renewing (bounded by the renewer's safety cap), while a clear "you
  # don't hold this" stops.
  def renewed?(slug)
    res = post("#{base(slug)}/review_claim/renew", { "session" => session_id, "nonce" => nonce })
    return true if res.nil? # board unreachable — not proof we lost the review

    res.code.to_i != 204
  end

  def stop_renewer(sid, slug)
    pid = read_renewer_marker(sid, slug)
    @killer.call(pid) if pid
    clear_renewer_marker(sid, slug)
  rescue StandardError
    nil
  end

  def spawn_detached(env, argv)
    pid = Process.spawn(env, *argv, out: File::NULL, err: File::NULL, pgroup: true)
    Process.detach(pid)
    pid
  end

  def terminate(pid)
    Process.kill("TERM", pid.to_i)
  rescue StandardError
    nil # already gone, or never ours to kill
  end

  # ── Rendering ────────────────────────────────────────────────────────────────

  # Report what the BOARD did, not what we hoped it did (the same lesson bin/devops-shift
  # learned: a 204 release means NOTHING was released, so don't claim success).
  def report_release(slug, res)
    if res.nil?
      @out.puts("review-claim: could not reach the board — the #{slug} review will lapse " \
                "on its own within ~#{lease_ttl_seconds}s.")
    elsif res.code.to_i == 204
      @out.puts("review-claim: #{slug} was not under review by this session — nothing released.")
    elsif ok?(res)
      @out.puts("review-claim: #{slug} review released.")
    else
      @out.puts("review-claim: the board refused the #{slug} release (HTTP #{res.code}) — " \
                "it will lapse within ~#{lease_ttl_seconds}s.")
    end
  end

  # THE WIRING GAP, told apart from a red build. `no_green_ci` is a WHOLE-QUEUE
  # verdict, and a repo whose Actions webhook never reached the board reads
  # exactly like one whose CI is still running — that ambiguity is how a 4/4-green
  # mcritchie-industries PR sat unclaimed in `submitted` for days. When the board
  # reports it holds NO ingested run for a skipped task's repo, say so plainly.
  def report_blind_repos(repos)
    repos = Array(repos).map(&:to_s).reject(&:empty?)
    return if repos.empty?

    @err.puts("claim-next-review: ⚠️  no CI is ingested for #{repos.join(', ')} — the board receives NO " \
              "GitHub Actions deliveries for #{repos.length == 1 ? 'it' : 'them'}, so its PRs can never read " \
              "green here however green GitHub is. This is a WIRING gap, not a red build: wire the repo's " \
              "Actions webhook to POST /api/v1/github/webhook (docs/agents/modules/deployment.md).")
  end

  # NAME THE SOURCE THE REFUSAL TRUSTED.
  #
  # This pop and `bin/dor-check --gate-role review` read DIFFERENT places, on
  # purpose: the pop folds the board's own ingested GitHub Actions rows (fast, one
  # query, no API budget), while dor-check reads `gh pr checks` LIVE for the one PR
  # in front of it. Both are right about what they read. When the board has not
  # ingested the PR's current tip they disagree about the SAME PR — the entry gate
  # refuses and gate-zero approves — and the task cannot be reviewed by the SOP at
  # all: the orchestrator cannot claim it, and forcing the lease by hand would make
  # the pop advisory whenever it is inconvenient.
  #
  # report_blind_repos does not cover it. That fires only when a repo has NO ingested
  # runs AT ALL; a wired repo missing just this HEAD prints nothing, which is how
  # auto-mint-level-up-tokens (turf PR 407) sat in `submitted` from 2026-08-23 and had
  # to be diagnosed by bisecting two CLIs. So state, plainly, what the board holds and
  # for WHICH commit — and hand over the one command that shows the other view.
  def report_skipped_ci(entries)
    entries = Array(entries).select { |e| e.is_a?(Hash) }
    return if entries.empty?

    @err.puts("claim-next-review: the board's OWN ingested CI is what this refusal read " \
              "(not a live GitHub call):")
    entries.each do |entry|
      slug = entry["slug"].to_s
      sha = entry["sha"].to_s
      @err.puts("  #{slug}: board holds #{entry['state']}" \
                "#{sha.empty? ? ' and NO run for this branch tip' : " for head #{sha}"}" \
                "#{entry['repo'].to_s.empty? ? '' : " (#{entry['repo']})"}")
    end
    @err.puts("  If GitHub shows this PR green, the board simply has not ingested that head — " \
              "an INGESTION gap, not a red build. Compare with: gh pr checks <pr> --repo <nwo>")
  end

  # The skip message: name the live reviewer so this session knows WHO has the task
  # and can move on to the next reviewable one. A `self_review` refusal is a
  # DIFFERENT skip — nobody holds the task, the claimer simply built it — so it
  # must not be reported as "already under review" with an empty holder line.
  def report_skip(slug, holder, disposition = "")
    return report_self_review_skip(slug) if disposition == "self_review"

    @out.puts("review-claim: ⏭️  #{slug} already under review — SKIP.")
    @out.puts("  #{holder_line(holder)}")
    @out.puts("  Another session is reviewing this task; pick the next reviewable one " \
              "(its lease lapses ~#{lease_ttl_seconds}s after it stops).")
  end

  # The no-self-review refusal: this soul is recorded as the task's builder
  # (devops.built_by), so it reviews nothing here. Not a race and not a wait —
  # re-running will never win it.
  def report_self_review_skip(slug)
    @out.puts("review-claim: ⛔ #{slug} — YOU BUILT THIS. A soul never reviews their own work — SKIP.")
    @out.puts("  The task records you as devops.built_by, so this claim is refused (not a race).")
    @out.puts("  Pick the next reviewable task. If the stamp is WRONG, correct it with")
    @out.puts("  bin/task move #{slug} building --actor <the-real-builder> and re-run.")
  end

  def holder_line(holder)
    label = holder["label"].to_s.strip
    who = label.empty? ? "session #{short(holder['session'])}" : "#{label} · session #{short(holder['session'])}"
    age = holder["heartbeat_age"]
    since = holder["acquired_at"].to_s
    age_txt = age.nil? ? "" : ", last heartbeat ~#{age}s ago"
    since_txt = since.empty? ? "" : " since #{since}"
    "#{who}#{since_txt}#{age_txt}"
  end

  # ── HTTP + helpers ───────────────────────────────────────────────────────────

  def base(slug)
    "/api/v1/tasks/#{slug}"
  end

  def post(path, body)
    tok = @api.token
    return nil unless tok

    res = @api.http_json(:post, path, body, bearer: tok)
    @api.invalidate_token! if res && res.code.to_i == 401
    res
  rescue StandardError
    nil
  end

  def get(path)
    tok = @api.token
    return nil unless tok

    res = @api.http_json(:get, path, nil, bearer: tok)
    @api.invalidate_token! if res && res.code.to_i == 401
    res
  rescue StandardError
    nil
  end

  def ok?(res)
    res && res.code.to_i.between?(200, 299)
  end

  def parse_data(res)
    body = JSON.parse(res.body)
    body.is_a?(Hash) ? (body["data"] || {}) : {}
  rescue StandardError
    {}
  end

  def parse_flags(argv)
    flags = {}
    i = 0
    while i < argv.length
      arg = argv[i]
      if arg.start_with?("--")
        nxt = argv[i + 1]
        if nxt.nil? || nxt.start_with?("--")
          flags[arg.delete_prefix("--")] = true
          i += 1
        else
          flags[arg.delete_prefix("--")] = nxt
          i += 2
        end
      else
        i += 1
      end
    end
    flags
  end

  # ── Argument validation (run BEFORE any command dispatch) ────────────────────

  # Every argument this command cannot account for: an unrecognized flag, a
  # single-dash token (which parse_flags drops on the floor entirely), and a
  # positional the command does not take. All three walked the same way parse_flags
  # walks the line, so a value-flag's VALUE (`--label Gastly`) is never mistaken
  # for an argument of its own — that fidelity is what keeps a VALID invocation
  # claiming instead of turning this guard into "refuse everything".
  def bad_arguments(command, argv)
    extra = positionals(argv)
    extra = extra.drop(1) if SLUG_COMMANDS.include?(command)
    unknown_flags(argv, COMMAND_FLAGS.fetch(command, [])) + extra
  end

  def unknown_flags(argv, valid)
    bad = []
    i = 0
    while i < argv.length
      arg = argv[i]
      if arg.start_with?("--")
        bad << arg unless valid.include?(arg)
        nxt = argv[i + 1]
        i += (nxt.nil? || nxt.start_with?("--")) ? 1 : 2
      else
        # A single-dash token is never a slug and never a flag parse_flags reads —
        # before this guard `-x` (and `-h`) vanished silently, side effect and all.
        bad << arg if arg.start_with?("-")
        i += 1
      end
    end
    bad
  end

  # The positionals on the line — flag VALUES consumed, dashed tokens excluded (a
  # dashed token is never a positional; unknown_flags reports it). The slug is the
  # first of these rather than `argv.find { !start_with?("--") }`, which read the
  # VALUE of a preceding value-flag as the slug: `acquire --label Gastly my-task`
  # claimed a task named "Gastly".
  def positionals(argv)
    found = []
    i = 0
    while i < argv.length
      arg = argv[i]
      if arg.start_with?("--")
        nxt = argv[i + 1]
        i += (nxt.nil? || nxt.start_with?("--")) ? 1 : 2
      else
        found << arg unless arg.start_with?("-")
        i += 1
      end
    end
    found
  end

  # Refuse LOUDLY: name every argument, list what IS valid, and say plainly that
  # nothing was claimed — an agent that typo'd a flag must never be left wondering
  # whether it took a lease. Exit CANT_RUN (1), the same code a missing session
  # gives, so an existing `|| true` caller branches exactly as it already does.
  def refuse(command, bad)
    valid = COMMAND_FLAGS.fetch(command, [])
    hint = valid.empty? ? " (this subcommand takes no flags)" : " (valid flags: #{valid.join(', ')})"
    noun = bad.length == 1 ? "argument" : "arguments"
    @err.puts("review-claim #{command}: unrecognized #{noun} #{bad.map(&:inspect).join(', ')}#{hint} — " \
              "NOTHING was claimed.")
    # A slug typed at `claim-next` is a caller who wanted `acquire`. Name the door
    # they meant: a refusal that only says no leaves them re-typing the same line.
    stray = bad.find { |arg| !arg.start_with?("-") }
    if command == "claim-next" && stray
      @err.puts("claim-next-review takes NO task slug — the BOARD picks the task. To review the one " \
                "you named: bin/task review-claim acquire #{stray}")
    end
    usage(CANT_RUN)
  end

  # The usage block --help prints and every refusal ends with. It goes to STDERR
  # deliberately: claim-next-review's STDOUT is the claimed slug (a caller runs
  # `slug=$(bin/task claim-next-review)`), so usage text on stdout would be
  # captured AS a slug. Returns the exit code it was handed, so a caller reads
  # `return usage(OK)`.
  def usage(code)
    @err.puts(<<~TEXT)
      usage: bin/task review-claim acquire <slug> [--label <text>] [--agent <soul>]
             bin/task review-claim release <slug> | status <slug> | renew <slug>
             bin/task claim-next-review [--label <text>] [--agent <soul>]
      `acquire` and `claim-next-review` are WRITES, not reads: each takes a real
      ~#{lease_ttl_seconds}s review lease on a real task. claim-next-review asks the BOARD for the
      next reviewable green-CI task, claims it, and prints its slug on stdout.
      Release what you claim: bin/task review-claim release <slug>
      exit: 0 claimed · 10 skipped (already under live review) · 4 nothing eligible · 1 could not run
    TEXT
    code
  end

  def session_id
    explicit = @env["TASK_REVIEW_CLAIM_SESSION"].to_s.strip
    return explicit unless explicit.empty?

    SessionIdentity.id(@env)
  end

  def nonce
    SessionIdentity.nonce(@env)
  end

  # The reviewing SOUL for the crew seat, or "". Reads the session's sticky
  # acting-agent — the same `.acting-agent` marker `bin/atomic-event heartbeat`
  # writes and every narration call already attributes to — so a reviewer that
  # narrates as itself (`--agent carl`) paints the right face with no extra flag.
  # Deliberately NOT the mascot: the mascot is the SESSION's identity, while the
  # crew seat asks who is REVIEWING.
  ACTING_AGENT_SUFFIX = ".acting-agent"

  def acting_agent(sid)
    SessionMarkers.read(sid, @api.projects_dir, ACTING_AGENT_SUFFIX).to_s.strip
  rescue StandardError
    ""
  end

  # The session's stable base mascot (for the skip message), or "".
  def session_mascot(sid)
    marker = SessionMarkers.read_session_marker(sid, @api.projects_dir) || {}
    marker["mascot"].to_s.strip
  rescue StandardError
    ""
  end

  # ── Local held-review marker (so release can stop the renewer it started) ─────
  # Path resolution AND the fail-closed sandbox guard both live on SessionMarkers —
  # this marker shares the narration store with .devops-shift/.open-activity, so it
  # shares their one choke point rather than re-deriving the path here.
  #
  # KEYED PER (session, TASK), not per session — this is where the per-TASK claim
  # departs from bin/devops-shift's per-ROLE lease. A shift session holds exactly
  # ONE lane, so one session-wide marker suffices. A pr-review session holds MANY
  # task claims at once (a --fast wave claims every task in the wave before it
  # releases any), so a single session-wide renewer marker would let release(taskA)
  # read and TERM taskB's renewer pid — taskB then lapses mid-review and a second
  # session could claim it, the exact double-review this gate prevents. The slug in
  # the suffix keeps each claim's marker (and its renewer) independent.
  REVIEW_CLAIM = ".task-review-claim"

  # The renewer's pid lives in its OWN marker rather than as a second line of
  # .task-review-claim, mirroring bin/devops-shift: a distinct reader might parse the
  # slug file, and widening a file another reader parses is how a small change breaks
  # a distant one.
  REVIEW_CLAIM_RENEWER = ".task-review-claim-renewer"

  # The per-(session, slug) marker suffix. Slugs are kebab-case (validated on the
  # board), so already filesystem-safe; sanitize defensively anyway.
  def marker_suffix(base, slug)
    "#{base}-#{slug.to_s.gsub(/[^A-Za-z0-9._-]/, '')}"
  end

  def write_marker(sid, slug)
    SessionMarkers.write(sid, @api.projects_dir, marker_suffix(REVIEW_CLAIM, slug), "#{slug}\n", env: @api.env)
  end

  def clear_marker(sid, slug)
    SessionMarkers.delete(sid, @api.projects_dir, marker_suffix(REVIEW_CLAIM, slug), env: @api.env)
  end

  def write_renewer_marker(sid, slug, pid)
    SessionMarkers.write(sid, @api.projects_dir, marker_suffix(REVIEW_CLAIM_RENEWER, slug), "#{pid}\n", env: @api.env)
  end

  def read_renewer_marker(sid, slug)
    pid = SessionMarkers.read(sid, @api.projects_dir, marker_suffix(REVIEW_CLAIM_RENEWER, slug)).to_s.strip.to_i
    pid.positive? ? pid : nil
  rescue StandardError
    nil
  end

  def clear_renewer_marker(sid, slug)
    SessionMarkers.delete(sid, @api.projects_dir, marker_suffix(REVIEW_CLAIM_RENEWER, slug), env: @api.env)
  end

  def usage_slug(cmd)
    @err.puts("review-claim #{cmd} needs a task slug (e.g. `bin/task review-claim #{cmd} some-task`)")
    CANT_RUN
  end

  def cant_run(message)
    @err.puts("review-claim: #{message}")
    CANT_RUN
  end

  def short(value)
    s = value.to_s
    s.length > 4 ? "…#{s[-4..]}" : s
  end

  def present?(value)
    @api.present?(value)
  end

  # The lease TTL for the skip/lapse copy — read from ClaimLease when the app libs are
  # loadable (they are in-repo), else the documented 120s default.
  def lease_ttl_seconds
    require_relative "../../lib/claim_lease"
    ClaimLease::DEFAULT_TTL_SECONDS
  rescue StandardError
    120
  end
end

if $PROGRAM_NAME == __FILE__
  exit(ReviewClaimCli.new.run(ARGV))
end

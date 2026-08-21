#!/usr/bin/env ruby
# frozen_string_literal: true

# ReleaseClaimCli — the per-RELEASE CONDUCTOR CLAIM cli, invoked by bin/release.rb
# around the two long release-lifecycle acts. It moves the QA-assemble and prod-deploy
# locks OFF the per-ROLE devops shift (bin/devops-shift) and ONTO the RELEASE record:
# `assembler` (prepare/qa-release) and `deployer` (ship/production-deploy) are two
# independent claim rows on the release. Because the lock lives on a record that turns
# over each release, a stale/ghost claim can never strand a GLOBAL lane again — the
# anti-stranding property the shift lease lacked. This is the mirror of
# bin/lib/review_claim_cli.rb one lane over (task → release, role), reusing the very
# same live-instance identity + TTL + detached-renewer machinery.
#
#   release-claim acquire <release-slug> --role <role> [--label <text>]  # take it, or stand down
#   release-claim renew   <release-slug> --role <role>                    # one heartbeat (internal)
#   release-claim release <release-slug> --role <role>                    # clean drop on completion
#   release-claim status  <release-slug> --role <role>                    # who (if anyone) holds it
#   release-claim renew-loop <release-slug> --role <role> --anchor-pid <p> --anchor-start <s>  # internal
#   release-claim <cmd> --help | -h                                       # usage; claims NOTHING
#
# EVERY ARGUMENT IS ACCOUNTED FOR BEFORE ANYTHING IS CLAIMED. --help/-h anywhere on the
# line prints usage and mutates nothing; an unrecognized flag, a single-dash token, a
# positional the subcommand does not take, and a value-flag that consumed no value all
# REFUSE (exit CANT_RUN) instead of running the side effect. Before this, unknown flags
# fell through parse_flags into an ignored key and the command ran anyway: `acquire
# <slug> --role deployer --help` PRINTED USAGE NOWHERE AND TOOK THE CLAIM, and a
# single-dash token was not even recorded as an ignored key — it vanished, side effect
# and all. This is the sibling of the same defect on bin/lib/review_claim_cli.rb, where
# a `claim-next-review --help` probe took a live review lease on a real task.
#
# HELP EXITS CANT_RUN (1) HERE, not OK — deliberately diverging from review_claim_cli.
# In THIS CLI exit 0 is not "the command worked", it is a claim-state ASSERTION:
# `acquire` 0 means "you hold the lease" (bin/release then RECORDS a held claim) and
# `any-live` 0 means "a release is live, withhold the workspaces". Answering a help
# probe with 0 would state a fact about the world that is not true — the very class of
# bug this guard closes. CANT_RUN is where every other usage error already lands, and
# both readers already treat it safely: bin/release fails OPEN, the reclaim guard
# fails CLOSED.
#
# `role` is `assembler` or `deployer`. Identity is the SAME live-instance identity the
# build claim, the shift lease, and the review claim use (session id + per-process
# nonce, SessionIdentity), so the renewer renews the right claim and — critically — a
# same-session, same-process re-acquire is a NO-OP RENEW: an interrupted `bin/release
# ship` re-run RESUMES its deployer claim instead of standing itself down.
#
# RENEWAL IS OWNED BY THE RUN, NOT BY THE UI: `acquire` starts a detached renewer
# (reusing bin/lib/shift_renewer.rb) anchored to the agent process, and `release`
# stops it — so a headless prepare/ship holds its claim for the act's whole life (many
# minutes), renewed cheaply over the fast HTTP AgentApi rather than a per-heartbeat
# `heroku run` dyno, and a crashed one frees the release within a TTL.
#
# EXIT CODES make the acquire gate scriptable (bin/release branches on it). This is the
# same table usage() prints, and the two must stay in step:
#   0  — acquired (you hold the claim; proceed to assemble/deploy this release).
#        For `any-live`: a live claim EXISTS — withhold the workspaces.
#   10 — stood down (a DIFFERENT live instance holds it; do NOT proceed)
#   3  — `any-live` only: no live claim; the workspaces are free to reclaim.
#   1  — could not run (no session id / no board / usage error, INCLUDING an argument
#        this CLI cannot account for) — fail OPEN so a telemetry hiccup never wedges a
#        real release.
# Best-effort and never raises. `renew`/`release`/`status` exit 0 on the happy path, but
# they are NOT unconditionally 0: a missing slug or role, a board `status` cannot read,
# and any refused argument all exit 1 from those subcommands too.

require "json"
require "fileutils"
require "rbconfig"
require_relative "agent_api"
require_relative "session_identity"
require_relative "session_markers"
require_relative "shift_renewer"

class ReleaseClaimCli
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  # Acquire exit codes (see header).
  OK = 0
  STOOD_DOWN = 10
  CANT_RUN = 1

  # `any-live` exit codes (bin/agent-worktree's _ship/_gate reclaim guard reads these):
  #   0 (OK)       — a live claim for the role exists (a ship is in progress) → WITHHOLD
  #   3 (NOT_LIVE) — the board answered: no live claim for the role → free to reclaim
  #   1 (CANT_RUN) — could not read the board → the caller decides (a destroy path
  #                  WITHHOLDS on can't-tell; a ship MIGHT be live).
  NOT_LIVE = 3

  # The two release-lifecycle roles (mirrors ReleaseConductorClaim::ROLES). A closed
  # set — an unknown role is a usage error, not a fail-open.
  ROLES = %w[assembler deployer].freeze

  # The reserved "forming" sentinel release_slug (mirrors ReleaseConductorClaim::
  # FORMING_SLUG). bin/release.rb runs STANDALONE — it never boots Rails, so it cannot
  # read the ActiveRecord model's constant; it reads the sentinel from here instead.
  # A drift-guard test pins both to the same literal.
  FORMING_SLUG = "__forming__"

  # --help/-h from ANY position prints usage and mutates nothing. The same two
  # spellings bin/task and review_claim_cli honor, because an agent probing this CLI
  # has no way to know it is a different parser.
  HELP_FLAGS = %w[--help -h].freeze

  # The flags each subcommand understands — the dictionary an unrecognized argument is
  # rejected against. A command with no optional flags still lists its required ones,
  # so this hash doubles as the set of subcommands run() dispatches; a key without a
  # `when` arm below is drift, and a test pins the two together.
  #
  # CHANGING THIS IS A WALL RISK, not a formality: every real invocation in the repo
  # must still parse. They are enumerated and replayed through this guard in
  # test/lib/release_claim_argument_guard_test.rb (REAL_ARGV), including the detached
  # renewer's own spawned line, which is captured from a live acquire rather than
  # hand-copied. A guard that refused THAT would lapse every conductor lease mid-act,
  # silently, because the renewer is spawned with out:/err: File::NULL.
  COMMAND_FLAGS = {
    "acquire"    => %w[--role --label],
    "renew"      => %w[--role],
    "renew-loop" => %w[--role --anchor-pid --anchor-start],
    "release"    => %w[--role],
    "status"     => %w[--role],
    "any-live"   => %w[--role]
  }.freeze

  # Every flag above takes a VALUE — this CLI has no boolean flags. parse_flags stores
  # `true` for a flag that consumed no token, and `true.to_s` is the string "true", so
  # a trailing `--label` silently labelled the claim "true". A flag that consumed
  # nothing is a usage error, not a boolean. A future BOOLEAN flag must be left out of
  # this list ON PURPOSE; a drift test fails until someone does so deliberately.
  VALUE_FLAGS = %w[--role --label --anchor-pid --anchor-start].freeze

  # The subcommands that name their own release. `any-live` deliberately does NOT: it
  # is the CROSS-release liveness read, so a slug on that line is a caller who meant
  # `status` — and answering about every release when they named one is the same silent
  # substitution as the dropped flag, one seam over.
  SLUG_COMMANDS = %w[acquire renew renew-loop release status].freeze

  # What a refusal COST the caller, per subcommand. One sentence for all of them would
  # be wrong in the DANGEROUS direction: "NOTHING was claimed" on a refused `release`
  # reads as "the lane is free" when in fact the claim is still held AND still being
  # renewed by its detached renewer, so it will not even lapse. Name the state the
  # caller is actually left in.
  REFUSAL_CONSEQUENCE = {
    "acquire"    => "NOTHING was claimed.",
    "renew"      => "NOTHING was renewed — the claim keeps ageing toward its lapse.",
    "renew-loop" => "NOTHING was renewed — the claim keeps ageing toward its lapse.",
    "release"    => "the claim was NOT released — it is STILL HELD, and its renewer keeps renewing it.",
    "status"     => "nothing was read; this says nothing about who holds the claim.",
    "any-live"   => "nothing was read; this says nothing about whether a release is live."
  }.freeze

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
  # ARGUMENT VALIDATION RUNS BEFORE DISPATCH, and that ordering is the whole point.
  # Unknown flags used to fall through parse_flags into an ignored key and the command
  # ran anyway on a line nobody had accounted for: `acquire <slug> --role deployer
  # --help` took a real conductor lease, and a single-dash token vanished without even
  # becoming an ignored key. An argument this CLI cannot account for now REFUSES rather
  # than assuming the rest of the line was what you meant.
  def run(argv)
    return usage(CANT_RUN) if argv.any? { |arg| HELP_FLAGS.include?(arg) }

    command = argv.shift
    return usage(CANT_RUN) unless COMMAND_FLAGS.key?(command)

    unknown, valueless = bad_arguments(command, argv)
    return refuse(command, unknown, valueless) if unknown.any? || valueless.any?

    # The slug is the first POSITIONAL — a value-flag's value (e.g. `--role deployer`)
    # must NOT be mistaken for it. A bare `argv.find { !start_with?("--") }` (the
    # review-claim shape, which has no value-flag before its slug) would pick up
    # `deployer` from `acquire --role deployer` when the slug is omitted, turning a
    # usage error into a spurious acquire; positionals() consumes flag values the same
    # way parse_flags does, so the slug is genuinely the leftover positional.
    slug = positionals(argv).first
    flags = parse_flags(argv)

    case command
    when "acquire"    then acquire(slug, flags)
    when "renew"      then renew(slug, flags)
    when "renew-loop" then renew_loop(slug, flags)
    when "release"    then release(slug, flags)
    when "status"     then status(slug, flags)
    when "any-live"   then any_live(flags)
    else usage(CANT_RUN) # drift guard: a COMMAND_FLAGS key with no arm here
    end
  rescue StandardError => e
    @err.puts("release-claim failed (ignored): #{e.class}: #{e.message}")
    CANT_RUN
  end

  # ── Commands ────────────────────────────────────────────────────────────────

  def acquire(slug, flags)
    return usage_slug("acquire") unless present?(slug)

    role = role_of(flags)
    return usage_role("acquire") unless role

    sid = session_id
    return cant_run("no session id — cannot identify this conductor") unless present?(sid)

    label = flags["label"].to_s.strip
    label = session_mascot(sid) if label.empty?
    res = post("#{base(slug)}/conductor_claim", { "role" => role, "session" => sid, "nonce" => nonce, "label" => label })
    return cant_run("no response from the board — proceeding without a conductor claim") unless ok?(res)

    data = parse_data(res)
    if data["acquired"]
      write_marker(sid, role, slug)
      start_renewer(sid, role, slug)
      @out.puts("release-claim: ✅ #{slug} #{role} claimed — this release is yours to #{verb(role)}.")
      OK
    else
      report_stand_down(slug, role, data["holder"] || {})
      STOOD_DOWN
    end
  end

  def renew(slug, flags)
    return usage_slug("renew") unless present?(slug)

    role = role_of(flags)
    return usage_role("renew") unless role

    sid = session_id
    return OK unless present?(sid) # best-effort heartbeat — never a failure

    post("#{base(slug)}/conductor_claim/renew", { "role" => role, "session" => sid, "nonce" => nonce })
    OK
  end

  # The detached renewer body (started by `acquire`; not for hand invocation). Renews
  # while the anchor process lives, so the claim lease follows the RUN and not the UI.
  # It inherits RELEASE_CONDUCTOR_CLAIM_SESSION + TASK_CLAIM_NONCE from its parent
  # because, once detached, it can no longer re-derive the live-instance identity by
  # walking its own ancestry — a renewer that guessed its nonce would renew NOTHING,
  # and every renew would 204 silently, which is indistinguishable from the bug it
  # exists to fix.
  def renew_loop(slug, flags)
    return usage_slug("renew-loop") unless present?(slug)

    role = role_of(flags)
    return usage_role("renew-loop") unless role

    pid = flags["anchor-pid"]
    start = flags["anchor-start"]
    ShiftRenewer.run(
      alive:   -> { SessionIdentity.process_alive?(pid, start) },
      renew:   -> { renewed?(slug, role) },
      sleeper: ->(seconds) { sleep(seconds) },
      clock:   -> { Time.now },
      interval: ShiftRenewer.interval_from(@env["RELEASE_CONDUCTOR_CLAIM_RENEW_INTERVAL"])
    )
    OK
  end

  def release(slug, flags)
    return usage_slug("release") unless present?(slug)

    role = role_of(flags)
    return usage_role("release") unless role

    sid = session_id
    res = (post("#{base(slug)}/conductor_claim/release", { "role" => role, "session" => sid, "nonce" => nonce }) if present?(sid))
    stop_renewer(sid, role, slug)
    clear_marker(sid, role, slug)
    report_release(slug, role, res)
    OK
  end

  def status(slug, flags)
    return usage_slug("status") unless present?(slug)

    role = role_of(flags)
    return usage_role("status") unless role

    res = get("#{base(slug)}/conductor_claim?role=#{role}")
    return cant_run("could not read conductor-claim status") unless ok?(res)

    holder = parse_data(res)["holder"]
    if holder.is_a?(Hash) && holder["live"]
      @out.puts("release-claim: #{slug} #{role} is held — #{holder_line(holder)}")
    else
      @out.puts("release-claim: #{slug} #{role} is free to claim.")
    end
    OK
  end

  # Is ANY claim for the role live (a ship in progress)? The CROSS-RELEASE liveness read
  # (no slug), for bin/agent-worktree's `_ship`/`_gate` reclaim guard. Exit 0 = live
  # (withhold the workspaces), NOT_LIVE = the board says none (free to reclaim), CANT_RUN
  # = could not read (the caller withholds — a ship MIGHT be live). Never raises.
  def any_live(flags)
    role = role_of(flags)
    return usage_role("any-live") unless role

    res = get("/api/v1/release_conductor_claims/live?role=#{role}")
    return cant_run("could not read #{role} claim liveness — cannot tell if a ship is live") unless ok?(res)

    data = parse_data(res)
    if data["live"]
      @out.puts("release-claim: a live #{role} claim exists — #{holder_line(data['holder'] || {})}")
      OK
    else
      @out.puts("release-claim: no live #{role} claim.")
      NOT_LIVE
    end
  end

  # ── The detached renewer ─────────────────────────────────────────────────────

  # Start a renewer for the claim we just took. No anchor process ⇒ no renewer: we
  # will not start a background process whose owner we cannot identify, because
  # nothing would ever tell it to stop. That case (a plain shell, CI) simply keeps the
  # old manual renewal, and we say so rather than implying cover we are not providing.
  def start_renewer(sid, role, slug)
    anchor = anchor_process
    unless anchor
      @out.puts("release-claim: note — no agent process to anchor a renewer to; " \
                "this #{role} claim lapses in ~#{lease_ttl_seconds}s unless something renews it.")
      return nil
    end

    argv = [RbConfig.ruby, __FILE__, "renew-loop", slug, "--role", role,
            "--anchor-pid", anchor[:pid].to_s, "--anchor-start", anchor[:start].to_s]
    pid = @spawner.call(renewer_env(sid), argv)
    write_renewer_marker(sid, role, slug, pid) if pid
    pid
  rescue StandardError => e
    @err.puts("release-claim: could not start the #{role} renewer (#{e.class}) — " \
              "the lease will rely on a manual renew as before.")
    nil
  end

  # The identity the renewer must carry. Detached, it cannot walk its way back to the
  # agent process, so both halves of the live-instance identity are handed down
  # explicitly — the nonce especially, since a wrong one renews nothing, silently.
  def renewer_env(sid)
    { "RELEASE_CONDUCTOR_CLAIM_SESSION" => sid.to_s, "TASK_CLAIM_NONCE" => nonce.to_s }
  end

  # The process to anchor the lease lifetime to. RELEASE_CONDUCTOR_CLAIM_ANCHOR_PID
  # lets a headless runner (or a test) name its own long-lived owner instead of relying
  # on a `claude`/`codex` ancestor being present.
  def anchor_process
    override = @env["RELEASE_CONDUCTOR_CLAIM_ANCHOR_PID"].to_s.strip
    return { pid: override.to_i, start: SessionIdentity.proc_start(override) } unless override.empty?

    SessionIdentity.agent_process
  end

  # One heartbeat from inside the loop. TRUE keeps the loop running. A definitive 204
  # means the board says we are no longer the holder — released elsewhere, or the claim
  # changed hands — so we stop. An unreachable board is NOT that: a network blip keeps
  # renewing (bounded by the renewer's safety cap), while a clear "you don't hold this"
  # stops.
  def renewed?(slug, role)
    res = post("#{base(slug)}/conductor_claim/renew", { "role" => role, "session" => session_id, "nonce" => nonce })
    return true if res.nil? # board unreachable — not proof we lost the claim

    res.code.to_i != 204
  end

  def stop_renewer(sid, role, slug)
    pid = read_renewer_marker(sid, role, slug)
    @killer.call(pid) if pid
    clear_renewer_marker(sid, role, slug)
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
  def report_release(slug, role, res)
    if res.nil?
      @out.puts("release-claim: could not reach the board — the #{slug} #{role} claim will lapse " \
                "on its own within ~#{lease_ttl_seconds}s.")
    elsif res.code.to_i == 204
      @out.puts("release-claim: #{slug} #{role} was not held by this session — nothing released.")
    elsif ok?(res)
      @out.puts("release-claim: #{slug} #{role} claim released.")
    else
      @out.puts("release-claim: the board refused the #{slug} #{role} release (HTTP #{res.code}) — " \
                "it will lapse within ~#{lease_ttl_seconds}s.")
    end
  end

  # The stand-down message: name the live conductor so the operator/agent knows WHO is
  # already assembling/deploying this release and can stop cleanly.
  def report_stand_down(slug, role, holder)
    @out.puts("release-claim: 🛑 #{slug} #{role} already held — STAND DOWN.")
    @out.puts("  #{holder_line(holder)}")
    @out.puts("  Another session is #{verb(role)}-ing #{slug}. Do not proceed; let it finish " \
              "(its lease lapses ~#{lease_ttl_seconds}s after it stops).")
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

  # The human verb for a role, for the acquire/stand-down copy.
  def verb(role)
    role == "deployer" ? "ship" : "assemble"
  end

  # ── HTTP + helpers ───────────────────────────────────────────────────────────

  def base(slug)
    "/api/v1/releases/#{slug}"
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

  # The positional args — argv with every `--flag`/`--flag value` pair removed, and
  # every dashed token excluded. Derived from the SAME each_argument walk the guard
  # uses (which in turn mirrors parse_flags), so the three can never disagree about
  # where a flag's value ends. The slug is positionals.first.
  #
  # A DASHED TOKEN IS NEVER A POSITIONAL, so it can never become the slug either —
  # unknown_flags reports it instead. Before the guard, `acquire -r deployer` resolved
  # its slug to the literal string "-r" and asked the board for a release by that name.
  def positionals(argv)
    found = []
    each_argument(argv) { |arg, _value| found << arg unless arg.start_with?("-") }
    found
  end

  # ── Argument validation (runs BEFORE any command dispatch) ───────────────────

  # Everything this command cannot account for, as [unknown, valueless]:
  #
  #   unknown   — an unrecognized flag, a single-dash token (which parse_flags drops
  #               on the floor entirely), and a positional the command does not take.
  #   valueless — a KNOWN value-flag that consumed no token, so parse_flags stored
  #               `true` for it and the command would have read the string "true".
  #
  # Two lists, not one, because they need different copy: `--label` is a real flag
  # typed wrong, not an argument nobody recognizes. Both walks consume flag values the
  # SAME way parse_flags does, so `--role deployer` is never mistaken for a stray
  # positional — that fidelity is what keeps a VALID invocation claiming instead of
  # turning this guard into "refuse everything".
  def bad_arguments(command, argv)
    valid = COMMAND_FLAGS.fetch(command, [])
    extra = positionals(argv)
    extra = extra.drop(1) if SLUG_COMMANDS.include?(command)
    [unknown_flags(argv, valid) + extra, valueless_flags(argv, valid)]
  end

  def unknown_flags(argv, valid)
    bad = []
    each_argument(argv) do |arg, _value|
      if arg.start_with?("--")
        bad << arg unless valid.include?(arg)
      elsif arg.start_with?("-")
        # A single-dash token is never a slug and never a flag parse_flags reads —
        # before this guard `-r` (and `-h`) vanished silently, side effect and all.
        # It consumes nothing, so whatever followed it lands in `extra` on its own.
        bad << arg
      end
    end
    bad
  end

  # A known value-flag that consumed NO token. Scoped to `valid` on purpose: an
  # unrecognized flag is already reported by unknown_flags, and naming it twice would
  # make a single typo look like two separate mistakes.
  def valueless_flags(argv, valid)
    bad = []
    each_argument(argv) do |arg, value|
      bad << arg if valid.include?(arg) && VALUE_FLAGS.include?(arg) && value.nil?
    end
    bad
  end

  # The ONE walk of the line, shared by every reader above so they can never disagree
  # about where a flag's value ends. Yields [token, consumed_value] — value is nil when
  # the token consumed nothing (a bare positional, a single-dash token, or a flag at
  # the end of the line or followed by another flag). The consumption rule is
  # parse_flags's, deliberately: a guard that split the line differently from the
  # parser would refuse lines the parser handles, or pass lines it mangles.
  def each_argument(argv)
    i = 0
    while i < argv.length
      arg = argv[i]
      if arg.start_with?("--")
        nxt = argv[i + 1]
        consumed = (nxt.nil? || nxt.start_with?("--")) ? nil : nxt
        yield(arg, consumed)
        i += consumed.nil? ? 1 : 2
      elsif arg.start_with?("-")
        # A single-dash token is not a flag to the parser, so it consumes NOTHING —
        # matching parse_flags exactly. Whatever followed it is classified on its own,
        # which is honest: the parser would have read it as a positional too.
        yield(arg, nil)
        i += 1
      else
        yield(arg, nil)
        i += 1
      end
    end
  end

  # Refuse LOUDLY: name every argument, list what IS valid, and say plainly what the
  # caller is left holding — an operator who typo'd a flag on `release` must never be
  # left believing the lane is free. Exit CANT_RUN (1), the same code every other usage
  # error gives, so bin/release still fails OPEN and the reclaim guard still fails
  # CLOSED, exactly as they already do.
  def refuse(command, unknown, valueless)
    valid = COMMAND_FLAGS.fetch(command, [])
    cost = REFUSAL_CONSEQUENCE.fetch(command, "NOTHING was done.")

    if unknown.any?
      noun = unknown.length == 1 ? "argument" : "arguments"
      hint = valid.empty? ? " (this subcommand takes no flags)" : " (valid flags: #{valid.join(', ')})"
      @err.puts("release-claim #{command}: unrecognized #{noun} #{unknown.map(&:inspect).join(', ')}#{hint} — #{cost}")
    end
    if valueless.any?
      verb = valueless.length == 1 ? "needs a value" : "need values"
      @err.puts("release-claim #{command}: #{valueless.join(', ')} #{verb} — #{cost}")
    end

    usage(CANT_RUN)
  end

  # The usage block --help prints and every refusal ends with. STDERR deliberately:
  # acquire/status/any-live print their human verdict on STDOUT and bin/release echoes
  # both streams into the release log, so usage on stdout would read as a verdict.
  # Returns the exit code it was handed, so a caller reads `return usage(CANT_RUN)`.
  def usage(code)
    @err.puts(<<~TEXT)
      usage: release-claim acquire <release-slug> --role <role> [--label <text>]
             release-claim release <release-slug> --role <role>
             release-claim status  <release-slug> --role <role>
             release-claim renew   <release-slug> --role <role>
             release-claim any-live --role <role>                       # cross-release liveness read
             release-claim renew-loop <release-slug> --role <role> --anchor-pid <p> --anchor-start <s>  # internal
      roles: #{ROLES.join(' | ')}
      `acquire` is a WRITE, not a read: it takes a real ~#{lease_ttl_seconds}s conductor lease on the
      release and starts a detached renewer that holds it for the whole act.
      Release what you claim: release-claim release <release-slug> --role <role>
      exit: 0 acquired (any-live: a live claim exists) · 10 stood down (another live conductor)
            · 3 any-live: no live claim · 1 could not run / usage
    TEXT
    code
  end

  # The role, normalized + validated against the closed ROLES set, or nil (a usage
  # error the caller reports). Unlike a slug, a bad role is NOT fail-open: renewing the
  # wrong role's claim is a silent no-op, exactly the failure this gate prevents.
  def role_of(flags)
    role = flags["role"].to_s.strip.downcase
    ROLES.include?(role) ? role : nil
  end

  def session_id
    explicit = @env["RELEASE_CONDUCTOR_CLAIM_SESSION"].to_s.strip
    return explicit unless explicit.empty?

    SessionIdentity.id(@env)
  end

  def nonce
    SessionIdentity.nonce(@env)
  end

  # The session's stable base mascot (for the stand-down message), or "".
  def session_mascot(sid)
    marker = SessionMarkers.read_session_marker(sid, @api.projects_dir) || {}
    marker["mascot"].to_s.strip
  rescue StandardError
    ""
  end

  # ── Local held-claim marker (so release can stop the renewer it started) ──────
  # Path resolution AND the fail-closed sandbox guard both live on SessionMarkers —
  # this marker shares the narration store with .devops-shift/.task-review-claim, so it
  # shares their one choke point rather than re-deriving the path here.
  #
  # KEYED PER (session, ROLE, SLUG) — NOT per (session, role) alone. A fresh-create
  # `bin/release prepare` briefly holds TWO assembler claims at once: the `__forming__`
  # SENTINEL guarding the promote, plus the real (rel_slug) claim it hands off to. A
  # role-only key would make them share one renewer-pid marker, so releasing the
  # sentinel would read the REAL claim's pid and TERM its renewer — the real claim then
  # lapses mid-assembly, the exact double-assembly this gate prevents. The slug in the
  # suffix keeps each claim's marker (and its renewer) independent, mirroring
  # review_claim_cli's per-slug keying.
  RELEASE_CLAIM = ".release-conductor-claim"

  # The renewer's pid lives in its OWN marker rather than as a second line of
  # .release-conductor-claim, mirroring bin/devops-shift: a distinct reader might parse
  # the slug file, and widening a file another reader parses is how a small change
  # breaks a distant one.
  RELEASE_CLAIM_RENEWER = ".release-conductor-claim-renewer"

  # The per-(session, role, slug) marker suffix. Roles are a closed set (safe); slugs
  # are kebab-case (validated on the board) plus the `__forming__` sentinel, all
  # filesystem-safe — sanitize defensively anyway.
  def marker_suffix(base, role, slug)
    "#{base}-#{role}-#{slug.to_s.gsub(/[^A-Za-z0-9._-]/, '')}"
  end

  def write_marker(sid, role, slug)
    SessionMarkers.write(sid, @api.projects_dir, marker_suffix(RELEASE_CLAIM, role, slug), "#{slug}\n", env: @api.env)
  end

  def clear_marker(sid, role, slug)
    SessionMarkers.delete(sid, @api.projects_dir, marker_suffix(RELEASE_CLAIM, role, slug), env: @api.env)
  end

  def write_renewer_marker(sid, role, slug, pid)
    SessionMarkers.write(sid, @api.projects_dir, marker_suffix(RELEASE_CLAIM_RENEWER, role, slug), "#{pid}\n",
                         env: @api.env)
  end

  def read_renewer_marker(sid, role, slug)
    pid = SessionMarkers.read(sid, @api.projects_dir, marker_suffix(RELEASE_CLAIM_RENEWER, role, slug)).to_s.strip.to_i
    pid.positive? ? pid : nil
  rescue StandardError
    nil
  end

  def clear_renewer_marker(sid, role, slug)
    SessionMarkers.delete(sid, @api.projects_dir, marker_suffix(RELEASE_CLAIM_RENEWER, role, slug), env: @api.env)
  end

  def usage_slug(cmd)
    @err.puts("release-claim #{cmd} needs a release slug (e.g. `release-claim #{cmd} rel-20260721 --role deployer`)")
    CANT_RUN
  end

  def usage_role(cmd)
    @err.puts("release-claim #{cmd} needs --role #{ROLES.join('|')}")
    CANT_RUN
  end

  def cant_run(message)
    @err.puts("release-claim: #{message}")
    CANT_RUN
  end

  def short(value)
    s = value.to_s
    s.length > 4 ? "…#{s[-4..]}" : s
  end

  def present?(value)
    @api.present?(value)
  end

  # The lease TTL for the stand-down/lapse copy — read from ClaimLease when the app
  # libs are loadable (they are in-repo), else the documented 120s default.
  def lease_ttl_seconds
    require_relative "../../lib/claim_lease"
    ClaimLease::DEFAULT_TTL_SECONDS
  rescue StandardError
    120
  end
end

if $PROGRAM_NAME == __FILE__
  exit(ReleaseClaimCli.new.run(ARGV))
end

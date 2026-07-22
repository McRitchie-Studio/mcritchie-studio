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
# EXIT CODES make the acquire gate scriptable (bin/release branches on it):
#   0  — acquired (you hold the claim; proceed to assemble/deploy this release)
#   10 — stood down (a DIFFERENT live instance holds it; do NOT proceed)
#   1  — could not run (no session id / no board / usage error) — fail OPEN so a
#        telemetry hiccup never wedges a real release.
# Best-effort and never raises; renew/release/status always exit 0.

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

  # The two release-lifecycle roles (mirrors ReleaseConductorClaim::ROLES). A closed
  # set — an unknown role is a usage error, not a fail-open.
  ROLES = %w[assembler deployer].freeze

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
  def run(argv)
    command = argv.shift
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
    else
      @err.puts("usage: release-claim acquire <release-slug> --role <role> [--label <text>] | " \
                "renew <release-slug> --role <role> | release <release-slug> --role <role> | " \
                "status <release-slug> --role <role> (roles: #{ROLES.join(', ')})")
      CANT_RUN
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

  # The positional args — argv with every `--flag`/`--flag value` pair removed, using
  # the SAME consumption rule as parse_flags, so a value-flag's value is never counted
  # as a positional. The slug is positionals.first.
  def positionals(argv)
    result = []
    i = 0
    while i < argv.length
      arg = argv[i]
      if arg.start_with?("--")
        nxt = argv[i + 1]
        i += (nxt.nil? || nxt.start_with?("--")) ? 1 : 2
      else
        result << arg
        i += 1
      end
    end
    result
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

#!/usr/bin/env ruby
# frozen_string_literal: true

# ReviewClaimCli — the per-TASK REVIEW CLAIM cli, backing `bin/task review-claim`.
# It lets MANY pr-review sessions run in parallel: each acquires the ONE task it
# picked (from GET /api/v1/tasks?stage=submitted&reviewable=1), and any session that
# finds a task already under LIVE review simply SKIPS it. This is the mirror of
# bin/devops-shift's ROLE lease one granularity down (lane → task), reusing the very
# same live-instance identity + TTL + detached-renewer machinery.
#
#   bin/task review-claim acquire <slug> [--label <text>]   # take the review, or skip
#   bin/task review-claim renew   <slug>                     # one heartbeat (internal)
#   bin/task review-claim release <slug>                     # clean drop when the review lands
#   bin/task review-claim status  <slug>                     # who (if anyone) is reviewing it
#   bin/task review-claim renew-loop <slug> --anchor-pid <p> --anchor-start <s>  # internal
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
    slug = argv.find { |a| !a.start_with?("--") }
    flags = parse_flags(argv)

    case command
    when "acquire"    then acquire(slug, flags)
    when "renew"      then renew(slug)
    when "renew-loop" then renew_loop(slug, flags)
    when "release"    then release(slug)
    when "status"     then status(slug)
    else
      @err.puts("usage: bin/task review-claim acquire <slug> [--label <text>] | renew <slug> | " \
                "release <slug> | status <slug>")
      CANT_RUN
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
    res = post("#{base(slug)}/review_claim", { "session" => sid, "nonce" => nonce, "label" => label })
    return cant_run("no response from the board — proceeding without a review claim") unless ok?(res)

    data = parse_data(res)
    if data["acquired"]
      write_marker(sid, slug)
      start_renewer(sid, slug)
      @out.puts("review-claim: ✅ #{slug} review claimed — this task is yours to review.")
      OK
    else
      report_skip(slug, data["holder"] || {})
      SKIPPED
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

  # The skip message: name the live reviewer so this session knows WHO has the task
  # and can move on to the next reviewable one.
  def report_skip(slug, holder)
    @out.puts("review-claim: ⏭️  #{slug} already under review — SKIP.")
    @out.puts("  #{holder_line(holder)}")
    @out.puts("  Another session is reviewing this task; pick the next reviewable one " \
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

  def session_id
    explicit = @env["TASK_REVIEW_CLAIM_SESSION"].to_s.strip
    return explicit unless explicit.empty?

    SessionIdentity.id(@env)
  end

  def nonce
    SessionIdentity.nonce(@env)
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

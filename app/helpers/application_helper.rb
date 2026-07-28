module ApplicationHelper
  def qa_environment?
    ENV["QA_ENV"].to_s.strip.downcase == "true"
  end

  def show_environment_banner?(qa_environment: qa_environment?, rails_env: Rails.env)
    !rails_env.production? || qa_environment
  end

  def environment_banner_message(qa_environment: qa_environment?, rails_env: Rails.env)
    return "QA Environment · Non-production" if qa_environment

    "#{rails_env.to_s.capitalize} Environment"
  end

  def stage_scheme(stage)
    case stage.to_s
    when "designed"                          then "info"
    when "submitted"                         then "warning"
    when "building", "reviewed", "assembled", "shipped" then "success"
    when "blocked"                           then "danger"
    else "neutral"
    end
  end

  # Human duration for time spent in a stage (seconds → "about 2 hours"). nil
  # when unknown — the genesis event has no prior stage to measure.
  def humanize_stage_duration(seconds)
    return nil if seconds.nil?
    return "under a minute" if seconds < 60

    distance_of_time_in_words(0, seconds)
  end

  # Tight one-token form of humanize_stage_duration for a corner pill on a
  # stacked avatar, where "about 2 hours" is too wide: "<1m" / "12m" / "3h" /
  # "5d". Shares the same nil contract (nil → render no pill); the full
  # humanize_stage_duration rides along as the avatar's title.
  def compact_stage_duration(seconds)
    return nil if seconds.nil?
    return "<1m" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  # A testing-phase span (Task::TestingPhases) → the duration cell text.
  # "completed" shows the measured length; "in_progress" the elapsed-so-far;
  # "missing" a dash (the phase never ran / isn't reached yet).
  def testing_phase_duration_label(span)
    case span["status"]
    when "completed"   then humanize_stage_duration(span["seconds"]) || "—"
    when "in_progress" then "#{humanize_stage_duration(span["seconds"]) || "under a minute"} so far"
    else "—"
    end
  end

  # Text-color utility for a testing-phase status chip. Theme-safe Tailwind palette
  # utilities already used elsewhere in the task views.
  def testing_phase_status_class(status)
    case status
    when "completed"   then "text-emerald-400"
    when "in_progress" then "text-amber-400"
    else "text-muted"
    end
  end

  # Tight one-cell form of testing_phase_duration_label for the /tasks/recent
  # scanning rows — precise_stage_duration's compact clock ("2h 4m") instead of
  # the wide "about 2 hours" prose, so 5 phase cells fit one row and columns
  # align for vertical scanning. In-progress cells get a trailing "+" (still
  # growing); missing renders the dash. The verbose label rides along as the
  # cell's title so nothing is lost.
  def testing_phase_compact_label(span)
    case span["status"]
    when "completed"   then precise_stage_duration(span["seconds"]) || "—"
    when "in_progress" then "#{precise_stage_duration(span['seconds']) || '<1m'}+"
    else "—"
    end
  end

  # A testing-phase span's iso8601 stamps → the {started_at:, ended_at:} Time
  # hash the deployment_range_date/_times helpers and the data-deployment-range
  # client re-stamp expect. nil when the phase never started (a missing span
  # renders no stamp stack) or when a stamp fails to parse (never raises into
  # a render).
  def testing_phase_range(span)
    started = span["started_at"].presence && Time.zone.parse(span["started_at"])
    return nil unless started

    ended = span["completed_at"].presence && Time.zone.parse(span["completed_at"])
    { started_at: started, ended_at: ended }
  rescue ArgumentError, TypeError
    nil
  end

  # Verdict glyph for a compact gate chip (/tasks/recent): ✓ passed, ✗ failed,
  # ● in flight (pairs with gate_status_class's amber). nil-safe → middot.
  def gate_verdict_glyph(run)
    case run&.status
    when "passed"    then "✓"
    when "failed"    then "✗"
    when "in_flight" then "●"
    else "·"
    end
  end

  # A gate run (GateRun) → the status chip text-color. Verdict-bearing, unlike
  # the phase chip above: passed/failed are terminal colors, in-flight ticks amber.
  def gate_status_class(run)
    case run&.status
    when "passed"    then "text-emerald-400"
    when "failed"    then "text-rose-400"
    when "in_flight" then "text-amber-400"
    else "text-muted"
    end
  end

  # "attempt 2 · 4m 12s" (in-flight runs read "… so far"); nil when no run yet.
  def gate_attempt_label(run)
    return nil if run.nil?

    duration = humanize_stage_duration(run.duration_seconds) || "under a minute"
    duration = "#{duration} so far" if run.in_flight?
    run.attempt.to_i > 1 ? "attempt #{run.attempt} · #{duration}" : duration
  end

  # A gate SOP entry's duration_ms → a compact human clock ("6m 52s", "41s",
  # "412ms" — the gates card was rendering raw seconds like "412.0s"). nil for
  # blank/zero so the view can skip the span entirely.
  def gate_sop_duration_label(duration_ms)
    ms = duration_ms.to_i
    return nil if ms <= 0

    ms < 1000 ? "#{ms}ms" : format_elapsed_clock(ms / 1000)
  end

  # ---- Phase-strip lane tiles + tile avatars (feature: phase-strip-lane-avatars)
  #
  # Two enrichments to the four-cell testing-phase strip (recent.html.erb + the
  # _testing_phases card): the two review LANES that break the overall Review
  # duration into its primary/light seats, and a small avatar per tile so the
  # operator sees WHO drove each phase at a glance. Sparse-first throughout — a
  # lane with no GateRun and an owner that doesn't resolve simply render nothing.

  # The review lanes riding beneath the overall Review tile: the primary (G2a)
  # and light (G2b) senior reviews. `gate_runs` is the {key => latest GateRun}
  # map both surfaces already load; returns [[key, label, run], …] in seat order
  # for only the lanes that have actually run (sparse-first, like the gate strip).
  REVIEW_LANE_TILES = [["g2a_primary", "Primary"], ["g2b_light", "Light"]].freeze

  def review_lane_tiles(gate_runs)
    runs = gate_runs || {}
    REVIEW_LANE_TILES.filter_map do |key, label|
      run = runs[key]
      [key, label, run] if run
    end
  end

  # The face a phase tile wears so the operator sees who drove it: the task's
  # Pokémon mascot owns the machine phases its session ran (Build, Local
  # Certification, CI); the Review phase wears the review-owner face passed in as
  # `avi:` (the caller resolves it from `review_avi`). `mascot_face` is a
  # MascotAgent (StageAgentsHelper#task_mascot_face); both quack for
  # #phase_face_avatar_tag. Returns the face, or nil when the phase has no owner or
  # the owner didn't resolve (the tile shows no face).
  PHASE_MASCOT_TILE_KEYS = %w[build local_certification ci].freeze

  def phase_tile_face(phase_key, mascot_face:, avi:)
    case phase_key.to_s
    when *PHASE_MASCOT_TILE_KEYS then mascot_face
    when "review"                then avi
    end
  end

  # The reviewer soul who ran a review lane, resolved from the GateRun's actor
  # slug. `lookup` is an optional preloaded {slug => Agent} map (batched on the
  # /tasks/recent list to avoid an N+1); nil when the run has no actor, or none
  # resolves.
  def gate_run_reviewer(run, lookup: nil)
    slug = run&.actor.presence
    return nil if slug.blank?

    lookup ? lookup[slug] : Agent.find_by(slug: slug)
  end

  # A compact circular avatar for a phase/lane tile corner. Mirrors the proven
  # components/agent_avatar pattern — a deterministic initial bubble underneath,
  # the face image over it, onerror drops a 404 back to the bubble (no
  # broken-image icon, no flicker) — but sized to `px` (the primitive floors at
  # 24px; the dense recency tiles want ~20px) and without the shiny badge (a
  # mascot's shiny already reads from its sprite). Any Agent-like `face` works
  # (an Agent or a MascotAgent). "" when face is nil (sparse-first).
  def phase_face_avatar_tag(face, px: 20, title: nil)
    return "".html_safe unless face

    dim = "#{px}px"
    tag.span(
      class: "relative inline-flex items-center justify-center rounded-full overflow-hidden shrink-0",
      style: "width:#{dim};height:#{dim};background-color:#{face.avatar_color};",
      title: title || face.name,
      data: { test: "phase-tile-avatar" }
    ) do
      initials = tag.span(face.avatar_initials,
                          class: "font-bold text-white leading-none",
                          style: "font-size:#{[(px * 0.42).round, 8].max}px;")
      image =
        if face.avatar.present?
          tag.img(src: face.avatar, alt: face.name, loading: "lazy",
                  class: "absolute inset-0 h-full w-full object-cover", onerror: "this.remove()")
        else
          "".html_safe
        end
      safe_join([initials, image])
    end
  end

  # Compact 12-hour clock for a board footer stamp: "3:32p" — no leading zero
  # on the hour, a single am/pm letter. Expects an already-zoned time.
  def clock_12h(time)
    return nil if time.blank?

    time.strftime("%-l:%M%P").sub(/m\z/, "")
  end

  # "Jul 7 3:32p" — a task's created-at stamp (the footer's left side, paired
  # with a 🌱 in the view). Rendered in the app's zone. nil-safe.
  def compact_created_stamp(time)
    return nil if time.blank?

    local = time.in_time_zone
    "#{local.strftime('%b %-d')} #{clock_12h(local)}"
  end

  # "4:09p" — a task's updated-at stamp (the footer's right side, paired with a
  # ✏️ in the view). Time only; the created stamp carries the date. nil-safe.
  def compact_updated_stamp(time)
    return nil if time.blank?

    clock_12h(time.in_time_zone)
  end

  # Two-unit humanizer for the deployment dashboards, where compact_stage_duration's
  # single-unit truncation ("1h" for 90 minutes) hides real differences between
  # deployments. Sub-minute and minute forms stay compact; the hour and day ranges
  # compound ("1h 30m", "2d 3h") so a longer phase never reads the same as a shorter
  # one. Shares the nil contract (nil → render the empty placeholder).
  def precise_stage_duration(seconds)
    return nil if seconds.nil?
    return "<1m" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600

    if seconds < 86_400
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      return minutes.zero? ? "#{hours}h" : "#{hours}h #{minutes}m"
    end

    days = seconds / 86_400
    hours = (seconds % 86_400) / 3600
    hours.zero? ? "#{days}d" : "#{days}d #{hours}h"
  end

  def release_duration_label(seconds, empty: "—")
    precise_stage_duration(seconds) || empty
  end

  # The (light) date for a /deployments stage cell's timestamp line, e.g.
  # "Jul 7, 2026". Rendered server-side in the app TZ as a fallback; the
  # deployment_range_script re-stamps it to the viewer's local date on load.
  def deployment_range_date(span)
    span[:started_at]&.in_time_zone&.strftime("%b %-d, %Y")
  end

  # The start→end time line for a stage cell, e.g. "3:32p → 4:01p" (drops the end
  # date when same-day, "→ …" while still running). App-TZ fallback; the
  # deployment_range_script overwrites it with the viewer's local clock.
  def deployment_range_times(span)
    started = span[:started_at]
    return nil unless started

    ended = span[:ended_at]
    return "#{deployment_clock(started)} → …" unless ended

    same_day = started.in_time_zone.to_date == ended.in_time_zone.to_date
    end_label = same_day ? deployment_clock(ended) : "#{ended.in_time_zone.strftime('%b %-d')} #{deployment_clock(ended)}"
    "#{deployment_clock(started)} → #{end_label}"
  end

  # 12-hour clock with a single-letter meridiem, no space — "3:32p" / "11:07a".
  def deployment_clock(time)
    time = time.in_time_zone
    "#{time.strftime('%-I:%M')}#{time.hour < 12 ? 'a' : 'p'}"
  end

  def release_duration_time(value)
    return "—" if value.blank?

    time = value.is_a?(String) ? Time.zone.parse(value) : value
    time ? l(time, format: :short) : "—"
  rescue ArgumentError, TypeError
    "—"
  end

  def release_duration_stage_name(key)
    Release::DurationCache::STAGE_DEFINITIONS.dig(key.to_s, "label") || key.to_s.humanize
  end

  RELEASE_RAINBOW_GLOW = {
    color: "#a78bfa",
    color_a: "#fb0094",
    color_b: "#00c4ff",
    border_mix: 58,
    shadow: "0 0 0 1px color-mix(in srgb, var(--task-card-glow-color) 44%, transparent), " \
            "0 0 34px color-mix(in srgb, var(--task-card-glow-color) 38%, transparent), " \
            "0 0 82px color-mix(in srgb, var(--task-card-glow-color) 22%, transparent), " \
            "0 0 118px color-mix(in srgb, var(--task-card-glow-color) 12%, transparent)"
  }.freeze

  def release_rainbow_glow_color
    RELEASE_RAINBOW_GLOW[:color]
  end

  def release_rainbow_glow_style(seed: nil, fresh_delay_ms: nil)
    glow = RELEASE_RAINBOW_GLOW
    style = []
    if seed
      style << "--studio-border-glow-offset: #{seed % 400}%;"
      style << "--studio-border-glow-duration: #{18 + (seed % 9)}s;"
      style << "--studio-border-glow-angle: #{38 + (seed % 18)}deg;"
    end
    style << "--lbfx-fresh-delay: -#{fresh_delay_ms.to_i}ms;" unless fresh_delay_ms.nil?
    style << "--task-card-glow-color: #{glow[:color]};"
    style << "--task-card-glow-color-a: #{glow[:color_a]};"
    style << "--task-card-glow-color-b: #{glow[:color_b]};"
    style << "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) #{glow[:border_mix]}%, transparent);"
    style << "--task-card-glow-shadow: #{glow[:shadow]};"
    style << "border-color: var(--task-card-glow-border-color);"
    style << "box-shadow: var(--task-card-glow-shadow);"
    style.join(" ")
  end

  def release_fresh_glow_style(release, elapsed_ms:)
    seed = release.to_param.to_s.each_byte.reduce(0) { |memo, byte| ((memo * 33) + byte) % 10_000 }
    release_rainbow_glow_style(seed: seed, fresh_delay_ms: elapsed_ms)
  end

  # The Last Release "fresh deploy" glow window, in milliseconds: how long a
  # just-shipped release glows before settling into read-only history. ONE
  # value drives every consumer — the server-rendered card state + glow phase
  # (tasks/_last_release), the FX partial's CSS animation durations and JS
  # cleanup timer (tasks/_deployments_live_fx), and the card's
  # data-fresh-window-ms attribute, which the release-ship e2e spec reads to
  # budget its waits. FRESH_DEPLOY_WINDOW_MS injects a wider window for the
  # e2e server (playwright.config.js webServer env): the production 8s window
  # raced that spec's own arrival waits under machine load — an expired glow is
  # a state you cannot wait back into (task stabilize-release-ship-spec).
  # Unparseable or non-positive values fall back to the default; a bad knob
  # must never 500 every /deployments render.
  FRESH_DEPLOY_WINDOW_DEFAULT_MS = 8_000
  def fresh_deploy_window_ms
    override = Integer(ENV["FRESH_DEPLOY_WINDOW_MS"].to_s, exception: false)
    override&.positive? ? override : FRESH_DEPLOY_WINDOW_DEFAULT_MS
  end

  def task_stage_count_classes(stage)
    case stage.to_s
    when "designed"  then "bg-blue-100 text-blue-800 border border-blue-200 dark:bg-blue-900/50 dark:text-blue-200 dark:border-blue-700/50"
    when "building"  then "bg-mint-100 text-mint-900 border border-mint-200 dark:bg-mint-900/50 dark:text-mint-200 dark:border-mint-700/50"
    when "submitted" then "bg-amber-100 text-amber-900 border border-amber-200 dark:bg-amber-900/50 dark:text-amber-200 dark:border-amber-700/50"
    when "reviewed"  then "bg-cyan-100 text-cyan-900 border border-cyan-200 dark:bg-cyan-900/50 dark:text-cyan-200 dark:border-cyan-700/50"
    when "assembled" then "bg-primary-100 text-primary-900 border border-primary-300 dark:bg-primary-900/50 dark:text-primary-200 dark:border-primary-700/50"
    when "shipped"   then "bg-green-100 text-green-900 border border-green-200 dark:bg-green-900/50 dark:text-green-200 dark:border-green-700/50"
    when "blocked"   then "bg-red-100 text-red-900 border border-red-200 dark:bg-red-900/50 dark:text-red-200 dark:border-red-700/50"
    when "archived"  then "bg-surface-alt text-muted border border-subtle"
    else "bg-surface-alt text-muted border border-subtle"
    end
  end

  def task_activity_badge_scheme(activity)
    case activity&.activity_type.to_s
    when "qa_feedback"    then "warning"
    when "clarification"  then "info"
    when "handoff"        then "success"
    else "violet"
    end
  end

  def task_activity_box_classes(activity)
    case activity&.activity_type.to_s
    when "qa_feedback"
      "border-amber-300 bg-amber-50/80 dark:border-amber-700/60 dark:bg-amber-950/30"
    when "clarification"
      "border-cyan-300 bg-cyan-50/80 dark:border-cyan-700/60 dark:bg-cyan-950/30"
    when "handoff"
      "border-mint-300 bg-mint-50/80 dark:border-mint-700/60 dark:bg-mint-950/30"
    else
      "border-subtle bg-inset/60"
    end
  end

  def release_state_classes(state)
    case state.to_s
    when "assembling" then "bg-blue-900/50 text-blue-300"
    when "assembled"  then "bg-amber-900/50 text-amber-300"
    when "shipped"    then "bg-green-900/50 text-green-300"
    when "abandoned"  then "bg-surface-alt text-muted"
    # Not a release STATE — the GEM-ONLY pill's tone (a violet 💎 gem accent),
    # rendered beside the state badge for a gem_only? release on _release_summary.
    when "gem_only"   then "bg-violet-900/50 text-violet-300"
    else "bg-surface-alt text-muted"
    end
  end

  # The conductor-owner FACE for one release role on the Next Release card — the
  # Pokémon of the SESSION that currently holds this release's ReleaseConductorClaim
  # for `role` ("assembler" = QA / bin/release prepare; "deployer" = production deploy
  # / bin/release ship). Resolves the claim's holder session → its SessionMascot's
  # Pokémon and renders the shared tasks/_release_owner_face partial (a small 24px
  # sprite; live = full-colour with a ring, idle = dimmed; the name in title/aria).
  # Returns nil — renders NOTHING — when no claim row exists yet, the claim has been
  # released (no holder session), or the holder session has no mascot, so a role that
  # has not been picked up shows no face. This is the ONE source both the initial
  # /deployments render AND the DeploymentsBroadcaster live morph read (both render
  # tasks/_release_summary), so the two paths never drift.
  #
  # STRICT READ: this runs on a GET render + a live morph, so it uses
  # SessionMascot.find_by — NOT SessionMascot.for (which is find-or-CREATE-with-draw).
  # A read must never MINT a mascot as a side effect; a holder session that never
  # drew one resolves to nil and renders nothing (mirrors the conductor-mascot row
  # just above, which reads rel.mascot without writing). The conductor's OWN session
  # drew its mascot at session start, so the face is present for every real holder.
  def release_role_owner_face(release, role)
    return nil if release.blank?

    info = ReleaseConductorClaim.status_for(release.slug, role)
    session = info && info["session"].presence
    return nil if session.blank?

    session_mascot = SessionMascot.find_by(session_id: session)
    pokemon = session_mascot&.pokemon
    return nil if pokemon.blank?

    render "tasks/release_owner_face",
           role: role,
           pokemon: pokemon,
           name: pokemon.name,
           label: release_owner_face_label(role, pokemon.name),
           shiny: session_mascot.shiny,
           live: info["live"] ? true : false
  end

  # The title/aria label for a conductor-owner face: which release ROLE this session
  # runs, then its Pokémon name — "QA (assembler): Pikachu" / "Deploy (deployer): Onix".
  def release_owner_face_label(role, name)
    prefix = role.to_s == "deployer" ? "Deploy (deployer)" : "QA (assembler)"
    "#{prefix}: #{name}"
  end

  # A task's PR-head CI progress (a Ci::CheckProgress) for the board card's
  # progress bar — blank until the task is submitted with a PR and a CI run
  # exists. The board preloads these in one batch (@ci_progress_by_slug); this is
  # the single-card fallback for the Turbo re-render path. Reads through
  # Ci::ProgressReader, which is cached and degrades to blank on any error.
  def task_ci_progress(task)
    ci_progress_reader.for_task(task)
  end

  # The G3 candidate suite CI progress for a release, ONE Ci::CheckProgress PER
  # MEMBER REPO: an ordered { repo_slug => progress } map (producer-first), so the
  # Next Release card renders one CI track per app whose code is in the release.
  # Empty ({}) unless the release is active. Same reader, same graceful degrade.
  def release_ci_progress(release)
    ci_progress_reader.for_release(release)
  end

  # The GitHub Actions run URL for one repo's release-CI track, or nil — the html_url
  # the Next Release card's G3 track links to (opened in a new tab). Resolved through
  # the same reader as release_ci_progress, so the link points at the EXACT run whose
  # progress that track charts. nil (no ingested run) -> the track renders unlinked,
  # never a broken href. Shared by the release card render and the live morph.
  def release_ci_run_url(release, repo)
    ci_progress_reader.release_ci_run_url(release, repo)
  end

  # One reader per request, so a page of cards shares its Github::Client + cache.
  def ci_progress_reader
    @ci_progress_reader ||= Ci::ProgressReader.new
  end

  # A folded CI check's coarse state -> how the SYMBOLIC row draws its icon (v1.2 of
  # visual-ci-progress-bars): a clean line SVG per check (the partial picks the
  # path). `color` is the state tint (green check / red x / amber loader), `spin`
  # animates the running loader, `label` is the accessible verb the icon stands for.
  # The pending entry is the safe fallback — an unknown state is never a phantom
  # pass/fail.
  CI_CHECK_SYMBOLS = {
    passed:  { label: "passed",  color: "text-emerald-600 dark:text-emerald-400", spin: false },
    failed:  { label: "failed",  color: "text-red-600 dark:text-red-400",         spin: false },
    pending: { label: "running", color: "text-amber-600 dark:text-amber-400",     spin: true }
  }.freeze

  def ci_check_symbol(check)
    CI_CHECK_SYMBOLS.fetch(check.state, CI_CHECK_SYMBOLS[:pending])
  end

  # The shared geometry for the card-width bars stacked on the board task card —
  # the status-flag CTAs (components/_card_status_bar) and the CI progress meter
  # (components/_ci_progress_slot) both build on it, so they read as one coherent
  # set: full width, the same radius, 1px border, and horizontal inset. Each caller
  # layers its own tone (bg / text / border colour) on top; the CI card's taller
  # two-row content is the only intended height difference.
  CARD_BAR_BASE_CLASSES = "w-full rounded border px-2 py-1"

  def card_bar_base_classes
    CARD_BAR_BASE_CLASSES
  end

  # The DevOps SOP vocabulary — the owner definition, the node types, and the four
  # accountability lanes (each step's expectation + gate) — is the SINGLE SOURCE OF
  # TRUTH in config/devops_vocabulary.yml, read via Devops::Vocabulary. Rename a term
  # there and it flows to /stages/sop in one edit. These thin helpers keep the view API.
  def sop_owner_definition
    Devops::Vocabulary.owner_definition
  end

  def devops_sop_lanes
    Devops::Vocabulary.lanes
  end

  def sop_node_type(type)
    Devops::Vocabulary.node_type(type)
  end

  # Pill classes for the post-ship production smoke SEAL badge (🟢/🔴) on a release
  # card — green = the @qa-readonly suite passed against prod, red = it failed.
  def release_smoke_seal_classes(seal)
    seal&.green? ? "bg-green-900/50 text-green-300" : "bg-red-900/50 text-red-300"
  end

  # The hover tooltip for the seal badge: the verdict line + when it was checked.
  def release_smoke_seal_title(seal)
    return "" unless seal

    when_text = seal.checked_at.present? ? " (checked #{time_ago_in_words(seal.checked_at)} ago)" : ""
    "#{seal.verdict_line}#{when_text}"
  end

  # Thin view API over the reader (mirrors release_ci_run_url), so one reader + cache
  # serves the whole card.
  def release_deploy_run_url(release, phase)
    ci_progress_reader.release_deploy_run_url(release, phase)
  end

  # ---- Per-repo release lanes (the /deployments tracker) ----------------------
  # One lane per member repo, each with four phase meters — Assembling · Deploying QA ·
  # Confirming · Deploying. Apps run all four; a library (gem) publishes at assembly, so
  # its QA slot becomes a "Published" meter and its Confirming/Deploying read n/a.
  # Assembling reuses the G3 CI reader; QA/Deploying read their per-repo deploy runs;
  # Confirming is the ONE coarse, release-grain (shared) meter, off the stage stamps.
  def release_repo_lanes(release)
    return [] if release.blank?

    ci_by_repo = release_ci_progress(release)
    release_lane_repos(release).map do |repo|
      gem = Release::Repos.gem?(repo)
      { repo: repo, emoji: app_emoji(repo), kind: gem ? "lib" : "app",
        phases: release_lane_phases(release, repo, ci_by_repo[repo], gem) }
    end
  end

  # Member repos, producer-first (gems before apps), one lane each.
  def release_lane_repos(release)
    release.ordered_members.filter_map { |task| task.release_repo.presence }.uniq
  end

  def release_lane_phases(release, repo, ci, gem)
    [
      release_meter_assembling(ci, url: release_ci_run_url(release, repo)),
      gem ? release_meter_published(ci) : release_meter_deploy(release, repo, "qa", start_stage: "qa_deploying", done_stage: "qa_deployed", key: "qa_deploying", label: "Deploying QA", done: "live ✓"),
      gem ? release_meter_na("Confirming") : release_meter_confirming(release),
      gem ? release_meter_na("Deploying") : release_meter_deploy(release, repo, "prod", start_stage: "prod_deploying", done_stage: "shipped", key: "production_deploying", label: "Deploying", done: "shipped ✓")
    ]
  end

  # Assembling = the repo's G3 CI, MEASURED — one mark per check drawn INSIDE the meter's
  # bar (tasks/_release_phase_meter), on a card that links to the same G3 run the retired
  # standalone bars did. `value` is no longer drawn; it survives as the card's hover title
  # and feeds its accessible name.
  def release_meter_assembling(ci, url: nil)
    ci ||= Ci::CheckProgress.blank
    state = if ci.blank? then :pending
    elsif ci.red? then :failed
    elsif ci.green? then :done
    else :running
    end
    { key: "assembling", label: "Assembling", state: state, coarse: false,
      value: (ci.present? ? (state == :done ? "#{ci.fraction_label} ✓" : ci.fraction_label) : "waiting"),
      percent: ci.percent, checks: (ci.present? ? ci : nil), url: url.presence }
  end

  # QA / Deploying — state comes from THIS release's own stage stamps (the deploy events
  # drive them: deploy_qa/deploy_prod started→running, completed→done), so a stale run
  # for the repo can never light a phase the release has not entered. The GitHub Actions
  # run is only read once the phase is REACHED — for the click-through link, and to flip
  # a stuck stage to :failed when the run came back failed. COARSE (no fraction).
  def release_meter_deploy(release, repo, phase, start_stage:, done_stage:, key:, label:, done:)
    reached_start = release.stage_reached?(start_stage)
    reached_done  = release.stage_reached?(done_stage)
    run = reached_start ? ci_progress_reader.release_deploy_run(release, repo, phase) : nil

    state = if reached_done then :done
    elsif reached_start
      (run && run[:status].to_s == "completed" && run[:conclusion].to_s != "success") ? :failed : :running
    else :pending
    end

    { key: key, label: label, state: state, coarse: false,
      value: release_deploy_meter_value(state, done),
      percent: (state == :done ? 100 : (state == :running ? 55 : 0)),
      checks: nil, url: (run && run[:url]) }
  end

  def release_deploy_meter_value(state, done_label)
    case state
    when :done then done_label
    when :running then "deploying"
    when :failed then "failed"
    else "—"
    end
  end

  # Confirming = the ONE coarse, shared, release-grain human gate. No fraction: pending
  # → running (indeterminate) → done, off the release's confirming/confirmed stamps.
  def release_meter_confirming(release)
    state = if release.stage_reached?("confirmed") then :done
    elsif release.stage_reached?("confirming") then :running
    else :pending
    end
    { key: "confirming", label: "Confirming", state: state, coarse: true,
      value: { done: "confirmed ✓", running: "confirming", pending: "waiting" }.fetch(state),
      percent: (state == :pending ? 0 : 100), checks: nil, url: nil }
  end

  # A gem publishes at assembly (producer-first) and has no server deploys — its QA slot
  # shows "Published", done once its CI is green.
  def release_meter_published(ci)
    published = ci&.green? || false
    { key: "published", label: "Published", state: (published ? :done : :pending), coarse: false,
      value: (published ? "gem live ✓" : "—"), percent: (published ? 100 : 0), checks: nil, url: nil }
  end

  # A phase that does not apply to this repo (a gem's Confirming/Deploying).
  def release_meter_na(label)
    { key: label.downcase, label: label, state: :na, coarse: false, value: "n/a", percent: 0, checks: nil, url: nil }
  end

  # Tailwind tones per meter state — fill colour + label/value text. Coarse (Confirming)
  # uses the studio PRIMARY (lavender) to read as the shared human gate; measured phases
  # use mint (done) / amber (running) / red (failed).
  #
  # `value` now paints marks that sit ON the fill, so the light-mode shades are DEEP (800/
  # 900) where they used to be 600. Same-hue-on-same-hue is how this went wrong once: a
  # mint-600 ✓ on a 30%-mint fill measured 1.73:1.
  #
  # EVERY pair below is MEASURED in a real browser against the bar it actually sits on
  # (light / dark, getComputedStyle → WCAG), not derived on paper — an arithmetic pass on
  # this table shipped two wrong figures once already:
  #
  #   done 5.76 / 5.25 · running 5.34 / 6.76 · failed 5.47 / 7.14 · pending 8.28 / 15.6
  #   n/a 9.48 / 11.75 — measured by hand, NOT by the spec (see below)
  #
  # e2e/release_meter_fit.spec.js re-measures the FOUR states its seed renders (done,
  # running, failed, pending) on every run and fails under 4.5:1, so those shades are caught
  # rather than argued about. It does NOT cover `:na` (no gem member in the seeded release —
  # a fourth member would break deployments_live's pill-count assertion), nor the overflow
  # mark, the indeterminate barber-pole, or the live pulse dot, none of which any seed draws.
  # Those are hand-measured figures with no guard behind them: treat them as stale until
  # re-measured. Saying "all of them" here when four states go unrendered would be the same
  # overclaim that let a failing red pair through a review.
  #
  # The `else` (pending) and `:na` rows carry no fill, so their text sits on bare bg-inset —
  # `text-muted` there measured 2.05:1 light / 4.04:1 dark, which is why they read as body
  # tone now. Those two branches are NOT decorative: pending is what every unstarted phase
  # on /deployments shows.
  def release_meter_tone(phase)
    coarse = phase[:coarse]
    case phase[:state].to_sym
    when :done
      coarse ? { fill: "bg-primary", value: "text-heading", label: "text-primary/80" }
             : { fill: "bg-mint-500", value: "text-mint-900 dark:text-mint-400", label: "text-muted" }
    when :running
      coarse ? { fill: "bg-primary/80", value: "text-heading", label: "text-primary/80" }
             : { fill: "bg-amber-400", value: "text-amber-800 dark:text-amber-300", label: "text-muted" }
    when :failed
      { fill: "bg-red-500", value: "text-red-800 dark:text-red-300", label: "text-muted" }
    when :na
      { fill: "bg-transparent", value: "text-body", label: "text-muted/50" }
    else
      { fill: "bg-transparent", value: "text-body", label: "text-muted" }
    end
  end

  # Bar width: a coarse RUNNING meter fills fully (the barber-pole animates it); every
  # other meter uses its measured percent (0 when pending).
  def release_meter_width(phase)
    return 100 if phase[:coarse] && phase[:state].to_sym == :running

    phase[:percent].to_i
  end

  # How many marks fit INSIDE a meter's bar. A mark is a fixed 8px box on a 2px gap, so 8
  # marks span 78px and 8 + the overflow mark 88px.
  #
  # The cap alone CANNOT keep the row inside the bar, and assuming it could is what shipped
  # a silent clip: the bar is 174px wide at a 1024px viewport but only 80px at 1280px (the
  # dashboard's `xl:grid-cols-2` halves the lane), so no fixed cap fits every width. The bar
  # therefore hides the marks below 99px and shows the fraction instead
  # (tasks/_release_phase_meter, a `@container` query on the bar's REAL width) — this cap
  # only bounds the wide case. Widths measured in-browser; the assertion lives in
  # e2e/release_meter_fit.spec.js, the only tier that can see a clip at all.
  RELEASE_METER_MARK_CAP = 8

  # Draw order for the marks: failures first, then still-running, then passes; ties broken
  # by check NAME.
  RELEASE_METER_MARK_RANK = { failed: 0, pending: 1, passed: 2 }.freeze

  # The marks a measured meter draws (Assembling): one per CI check, capped as above, plus
  # a trailing :overflow sentinel when the suite runs past the cap. :passed/:failed draw as
  # ✓/✗ glyphs; :pending draws as a SPINNER (the same house loader
  # components/_ci_progress_symbols uses), so a running suite reads as live rather than as
  # a row of inert circles. Rendered by tasks/_release_phase_meter.
  #
  # Sorted, because the source is not: CiCheckJob.progress_rows plucks without an ORDER BY,
  # so raw order is Postgres heap order and RESHUFFLES as rows are updated — and the card
  # re-renders on every CI upsert, so unsorted marks would jitter during exactly the running
  # suite this meter is for.
  #
  # Sorted by SEVERITY first (then name), because sorting by name alone let the cap decide
  # by alphabet: a failing `zz-lint` fell outside a full row of passing `aa-*` checks, so a
  # red meter drew nothing but ✓. Severity-first means the failures are the marks that
  # survive the cap. Both orders are stable across re-renders; only this one is honest.
  def release_meter_check_marks(ci, cap: RELEASE_METER_MARK_CAP)
    return [] if ci.blank?

    marks = ci.checks.map { |check| [check.failed? ? :failed : (check.pending? ? :pending : :passed), check.name.to_s] }
                     .sort_by { |mark, name| [RELEASE_METER_MARK_RANK.fetch(mark), name] }
                     .first(cap).map(&:first)
    marks << :overflow if ci.total > cap
    marks
  end

  # Compact single-unit "time ago" for the session filter — the smallest legible
  # unit (m/h/d/w, or "just now" under a minute) so a dense session list still reads
  # recency at a glance. It keeps climbing past hours into days and weeks (d/w)
  # since a session can be idle for days. A blank time (a session with no timestamped
  # signal) → nil so the caller renders nothing; a sub-minute or future time reads
  # "just now" (never "0m ago", never a negative label).
  def compact_time_ago(time, now: Time.current)
    return nil if time.blank?

    seconds = [(now - time).to_i, 0].max
    return "just now" if seconds < 60
    return "#{seconds / 60}m ago" if seconds < 3_600
    return "#{seconds / 3_600}h ago" if seconds < 86_400
    return "#{seconds / 86_400}d ago" if seconds < 604_800

    "#{seconds / 604_800}w ago"
  end

  # Release-card status badge label. Folds the bare state and its relative time
  # into one pill ("Shipped 7 minutes ago" / "Assembled 2 hours ago") so the card
  # no longer repeats the state and a separate "shipped X ago" line. Falls back to
  # the capitalized state when no timestamp applies (e.g. an in-progress
  # "Assembling" release, or a shipped release with no recorded shipped_at).
  def release_state_label(release, current: false)
    if release.shipped_at
      "Shipped #{time_ago_in_words(release.shipped_at)} ago"
    elsif current && release.assembled_at
      "Assembled #{time_ago_in_words(release.assembled_at)} ago"
    else
      release.state.to_s.capitalize
    end
  end

  # The single timing line shown next to a release's conductor mascot: how long an
  # ACTIVE release has been in progress since it began ("in progress · 23m"), or
  # how long a SHIPPED release took begin→ship ("took 18m"). nil when neither
  # applies (a not-yet-shipped, non-active state, or missing timestamps) so the
  # card renders no timing. Reuses compact_stage_duration for the tight one-token
  # form. `now` is injectable for deterministic tests.
  def release_timing_label(release, now: Time.current)
    if release.active?
      elapsed = elapsed_seconds(release.created_at, now)
      label = compact_stage_duration(elapsed)
      label && "in progress · #{label}"
    elsif release.shipped_at
      took = elapsed_seconds(release.created_at, release.shipped_at)
      label = compact_stage_duration(took)
      label && "took #{label}"
    end
  end

  # Whole, non-negative seconds between two times, or nil when either is missing.
  # Clamps a (clock-skew) negative span to 0 rather than rendering a bogus past.
  def elapsed_seconds(from, to)
    return nil unless from && to

    [(to - from).to_i, 0].max
  end

  # The elapsed clock for the ACTIVE Next Release ticker -- the SERVER-side
  # initial value the _release_ticker JS then advances every second ("45s" /
  # "7m 23s" / "1h 04m"). Mirrors that JS `fmt()` EXACTLY so the first tick
  # doesn't jump format. `now` is injectable for deterministic tests.
  def release_elapsed_clock(release, now: Time.current)
    format_elapsed_clock(elapsed_seconds(release.created_at, now) || 0)
  end

  # secs -> tight elapsed clock, dropping leading-zero units and zero-padding
  # trailing units while they tick: "45s", "7m 23s", "1h 04m". At an hour the
  # UI switches to hours + minutes and drops seconds.
  def format_elapsed_clock(secs)
    secs = secs.to_i
    return "#{secs}s" if secs < 60

    minutes, seconds = secs.divmod(60)
    return format("%dm %02ds", minutes, seconds) if minutes < 60

    hours, mins = minutes.divmod(60)
    format("%dh %02dm", hours, mins)
  end

  # Canonical app/repo slug → emoji map for the compact app indicators on task
  # cards and current-release member pills. Mirrors the glyphs in
  # ReleaseNotes::Formatter::APP_GROUPS (kept independent so views don't reach
  # into the service); keep the two in sync if an app is added or its glyph
  # changes.
  APP_EMOJIS = {
    "mcritchie-studio" => "🪎",
    "turf-monster"     => "🐊",
    "studio-engine"    => "💎",
    "turf-vault"       => "🏛️",
    "vault"            => "🏛️",
    "solana-studio"    => "🧱",
    "chain-ops"        => "⛓️",
    "rolio"            => "📇"
  }.freeze

  # Emoji for a single repo/app slug, or nil when the slug is unmapped/blank.
  def app_emoji(repo)
    APP_EMOJIS[repo.to_s.strip.downcase]
  end

  # Order-preserving, de-duplicated emoji list for a set of repo slugs. Two
  # aliases that share a glyph (turf-vault/vault) collapse to one.
  def app_emojis(repos)
    Array(repos).filter_map { |repo| app_emoji(repo) }.uniq
  end

  # Inline emoji cluster (one glyph per mapped repo) for a set of repo slugs,
  # titled with the repo list — or nil when nothing maps. Centralizes the markup
  # shared by the task card's slug row and the current-release member pills;
  # callers pass layout classes via +css+.
  def app_emoji_badge(repos, css: "leading-none")
    emojis = app_emojis(repos)
    return if emojis.none?

    tag.span(emojis.join(" "), class: css, title: Array(repos).join(", "))
  end

  # Single source for the right-edge fade mask used on the task card's single-line
  # rows (the slug + the footer meta): a transparency mask so the text fades out on
  # overflow without a solid bg gradient that would mismatch the card colour on
  # hover. +stop+ is the opaque cutoff (% before the fade). Mirrored — not shared —
  # by components/_overflow_fade, which drives its own L/R mask through Alpine.
  def right_fade_style(stop: 88)
    "mask-image: linear-gradient(to right, #000 #{stop}%, transparent); " \
      "-webkit-mask-image: linear-gradient(to right, #000 #{stop}%, transparent)"
  end

  # Canonical copy-paste kickoff commands for the DevOps (Deploy) lane — the
  # single source of truth shared by the /stages cards and the last-release
  # archive chip. The per-stage entries are
  # keyed by DevOps board stage and kept terse (≤3 words) so each fits a column
  # header; the feature-agent lane has none.
  #
  # The four legacy release-wide meta-trigger chips (Avi Heartbeat Slow/Fast,
  # Build and Deploy QA Release, Merge Assemble Deploy) were retired in favor of
  # the soul heartbeat launchers in +heartbeat_launchers+ (Carl owns pr-review +
  # pr-review-slow; Alex gains the full-cycle act that carries the former
  # Merge/Assemble/Deploy).
  def devops_kickoffs
    {
      "submitted" => "Review submitted PRs",
      "reviewed"  => "Prepare release",
      "assembled" => "Run Deployment",
      "shipped"   => "Archive completed tasks"
    }
  end

  # The four soul-avatar heartbeat launchers shown on the standalone Heartbeats
  # card (tasks/_heartbeats_card on /deployments, one tasks/_heartbeat_launcher
  # per soul): a soul face (linking to /agents/<slug>) over a
  # PROMPT-LIKE row 1 plus one or more copyable atom acts. Every row is an
  # INDEPENDENTLY-copyable valid launch
  # prompt. +heartbeat+ (row 1) is the prompt-like soul heartbeat phrase — one per
  # soul ("Carl Heartbeat" / "Avi Heartbeat" / "Steffon Heartbeat" / "Alex
  # Heartbeat"); +actions+ are the launcher acts that scope that heartbeat's work
  # (Carl: pr-review + pr-review-slow; Avi: qa-release + deploy-with-task; Steffon:
  # production-deploy + archive-shipped; Alex: grade-events + share-insights +
  # full-cycle). +agent_slug+
  # resolves the soul avatar (reused from the heartbeat Agent column + stage
  # timeline) AND its /agents/<slug> link; +label+ is the small purpose caption;
  # +title+ is the hover tooltip. Every row (the heartbeat prompt and each act) is
  # genuinely launchable on its own; each is a recognized launcher in
  # docs/agents/modules/heartbeats.md + the per-agent HEARTBEAT.md launchers.
  def heartbeat_launchers
    [
      { agent_slug: "carl",    heartbeat: "Carl Heartbeat",    actions: ["pr-review", "pr-review-slow"],                   label: "Review",        title: "Carl — review submitted PRs, one Carl per PR (review-only)" },
      { agent_slug: "avi",     heartbeat: "Avi Heartbeat",     actions: ["qa-release", "deploy-with-task"],                label: "Assemble + QA", title: "Avi — sweep reviewed work onto release, then QA the candidate" },
      { agent_slug: "steffon", heartbeat: "Steffon Heartbeat", actions: ["production-deploy", "archive-shipped"],          label: "Ship + archive", title: "Steffon — ship a QA-green release, then archive shipped work" },
      { agent_slug: "alex",    heartbeat: "Alex Heartbeat",    actions: ["grade-events", "share-insights", "full-cycle"], label: "Learn + ship",  title: "Alex — grade, share insights, + full DevOps cycle heartbeat" }
    ]
  end

  # One-line "what it does" caption for each heartbeat launcher act, keyed by the
  # act slug used in +heartbeat_launchers+. Sourced from
  # docs/agents/modules/heartbeats.md so the agent profile page can annotate each
  # copyable phrase with the work it launches — one caption per act registered in
  # +heartbeat_launchers+.
  ACTION_DESCRIPTIONS = {
    "pr-review"         => "Review all submitted PRs (review-only — Avi sweeps)",
    "pr-review-slow"    => "Review submitted PRs one at a time",
    "production-deploy" => "Ship a QA-ready release to production",
    "qa-release"        => "Prepare + deploy the QA release",
    "archive-shipped"   => "Archive shipped tasks + releases",
    "grade-events"      => "Grade 10 recent events for quality",
    "share-insights"    => "Share confirmed insights into the docs",
    "full-cycle"        => "Full cycle — review, assemble, QA, ship to prod",
    "deploy-with-task"  => "Expedite ONE task to prod (asks: what task?)"
  }.freeze

  def action_description(act)
    ACTION_DESCRIPTIONS[act.to_s]
  end

  # Leading icon for each heartbeat launcher act. The four ORDERED release-pipeline
  # acts get a 1→4 keycap so the buttons read as a sequence across the souls (Carl
  # pr-review 1 → Avi qa-release 2 → Steffon production-deploy 3 → Steffon
  # archive-shipped 4); the off-sequence acts get a themed glyph (🐢 slow review,
  # 🧑🏻‍🏫 grading, 🌎 the whole cycle, ⚡ the single-task expedite). The heartbeat row
  # itself gets a ❤️ in the view.
  ACTION_ICONS = {
    "pr-review"         => "1️⃣",
    "qa-release"        => "2️⃣",
    "production-deploy" => "3️⃣",
    "archive-shipped"   => "4️⃣",
    "pr-review-slow"    => "🐢",
    "grade-events"      => "🧑🏻‍🏫",
    "share-insights"    => "📡",
    "full-cycle"        => "🌎",
    "deploy-with-task"  => "⚡"
  }.freeze

  def action_icon(act)
    ACTION_ICONS[act.to_s]
  end

  # The heartbeat launcher owned by a given soul, or nil for an agent that has no
  # heartbeat (Carl / Shannon / Jasper). Lets the agent profile page render the
  # HEARTBEAT section only for souls that own one, and skip it gracefully for the
  # rest.
  def heartbeat_launcher_for(agent_slug)
    heartbeat_launchers.find { |l| l[:agent_slug] == agent_slug.to_s }
  end

  # The two-workflow stage guide rendered on /stages (vertical swimlanes). One
  # entry per stage: what it means, who's responsible, and what moves it next.
  # `submitted` is the shared seam, so it appears in both lanes.
  def devops_stage_guide
    {
      "Build" => [
        { stage: "designed",
          what: "Spec complete — acceptance criteria, change shape, test plan, and affected repos are all set. No code yet.",
          who: "Author / operator", nxt: "An agent claims it (passes dor-check --gate build) → building" },
        { stage: "building",
          what: "An agent owns the task in an isolated worktree, writing the code and its tests together. A BLOCK is a building attribute (not a stage): a blocked task glows red in this column, recording where it stalled (blocked_from), who raised it (blocked_by), and why (block_kind) until it's resumed.",
          who: "Feature agent (whoever can unblock it — agent for rework, operator for environment)", nxt: "Open a PR, pass dor-check --gate merge → submitted" },
        { stage: "submitted",
          what: "The PR is open and the feature agent's part is done — the seam where Build hands off to DevOps.",
          who: "Feature agent → DevOps", nxt: "DevOps picks it up for review → reviewed" }
      ],
      "Deploy" => [
        { stage: "submitted", kick: devops_kickoffs["submitted"],
          what: "The intake queue — submitted PRs waiting for review. The review session spins ONE Carl per PR: the standing primary AND owner (there is no Avi supervisor). Carl runs the deep technical review, owns the gates, summons a domain LIGHT at his discretion from {Shannon · Jasper · Steffon · Alex} via reviewer-select, drives the verdict, and merges the feat PR into accepted.",
          who: "Carl (standing primary + owner) → domain LIGHT",
          tests: "Base tier — unit + component. Carl + the light confirm green, plus code standards, smell, scalability, and acceptance.",
          gate: "A merge-ready verdict (Carl = Opus on migration / payment / solana / auth). One complete qa_feedback on a fail.",
          nxt: "Merge-ready, no blocker → Carl merges into accepted + drives reviewed; one block → rework" },
        { stage: "reviewed",  kick: devops_kickoffs["reviewed"],
          what: "Merged onto accepted and ready for Avi's self-healing qa-release sweep, which promotes the accepted → release batch PR and flips members only after QA-green.",
          who: "Avi (Product Owner)",
          tests: "Integration + an e2e smoke on origin/release before QA deploy; review's green base tests carry forward.",
          gate: "Deterministic sweep honoring dependencies + lanes; conflicts surface at PR-merge and block only the affected task.",
          nxt: "Avi runs bin/release prepare → QA deploy → assembled on QA-green" },
        { stage: "assembled", kick: devops_kickoffs["assembled"],
          what: "The accepted → release batch PR is merged and the release candidate is built; Avi QAs it and deploys origin/release to QA.",
          who: "Avi (Product Owner)",
          tests: "Integration + an e2e smoke on origin/release (the next tier up from review).",
          gate: "Deterministic suite — a regression blocks the task. No human approval at this step.",
          nxt: "Green → bin/release prepare deploys to QA + a Discord note. The ship decision is at ship, not here" },
        { stage: "shipped",   kick: devops_kickoffs["shipped"],
          what: "Live in production and shown as the board's Last Release; release notes are posted as part of Run Deployment.",
          who: "Steffon (tests the frozen SHA) → operator gate or autonomous deploy trigger",
          tests: "Full e2e + highest tier on the FROZEN ship SHA (the exact prod code — fixes 'shipped ≠ tested').",
          gate: "🔒 Avi's qa-release stops for the operator at QA; Steffon's production-deploy (or the Alex full-cycle) grants ship authority after the same gates pass.",
          nxt: "On explicit ship authority: bin/release ship ff's release → main, deploys prod → shipped, then Archive completed tasks" }
      ]
    }
  end

  # Render a stage-guide "Next →" line, turning any stage word into its colored
  # badge (so "→ assembled" shows the same pill as the column). Escapes first,
  # then injects badge markup for whole-word stage matches only.
  def devops_next_html(text)
    stages = Task::STAGE_LABELS.keys
    pattern = /\b(#{stages.join('|')})\b/
    ERB::Util.html_escape(text).to_str.gsub(pattern) do |word|
      tag.span(Task::STAGE_LABELS.fetch(word),
               class: "inline-block px-1.5 py-0.5 rounded text-[11px] font-bold align-baseline #{task_stage_count_classes(word)}")
    end.html_safe
  end

  def news_stage_scheme(stage)
    case stage.to_s
    when "new"        then "stage-fresh"
    when "reviewed"   then "stage-shaping"
    when "processed"  then "stage-structured"
    when "refined"    then "stage-refined"
    when "concluded"  then "stage-cohered"
    when "archived"   then "stage-closed"
    else "neutral"
    end
  end
end

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

  def release_duration_label(seconds, empty: "—")
    compact_stage_duration(seconds) || empty
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
    else "bg-surface-alt text-muted"
    end
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

  RELEASE_TRACKER_STAGES = [
    { key: "testing", active_label: "Testing", complete_label: "Tested" },
    { key: "assembling", active_label: "Assembling", complete_label: "Assembled" },
    { key: "qa_deploying", active_label: "Deploying QA", complete_label: "Live on QA" },
    { key: "confirming", active_label: "Confirming", complete_label: "Confirmed" },
    { key: "production_deploying", active_label: "Deploying", complete_label: "Deployed" }
  ].freeze

  # Pizza-tracker progress for the active release card, derived from the durable
  # writes the conductor already makes during bin/release merge/prepare/ship.
  def release_tracker_steps(release, now: Time.current)
    done_count = release_tracker_done_count(release)
    events = release.release_events.to_a

    RELEASE_TRACKER_STAGES.each_with_index.map do |stage, index|
      state =
        if index < done_count
          :complete
        elsif index == done_count && done_count < RELEASE_TRACKER_STAGES.size
          :active
        else
          :pending
        end

      stage.merge(
        index: index + 1,
        label: release_tracker_step_label(stage, state),
        state: state,
        connector_state: release_tracker_connector_state(index, done_count)
      ).merge(
        release_tracker_duration(release, stage[:key], state, events: events, now: now)
      )
    end
  end

  def release_tracker_duration(release, key, state, events:, now: Time.current)
    started_at, completed_at = release_tracker_duration_bounds(release, key, events)
    if state.to_sym == :active
      started_at ||= release_tracker_fallback_started_at(release, key)
      return {} unless started_at

      return {
        duration_seconds: elapsed_seconds(started_at, now),
        duration_started_at: started_at,
        duration_live: true
      }
    end

    return {} unless state.to_sym == :complete

    completed_at ||= release_tracker_fallback_completed_at(release, key)
    started_at ||= release_tracker_fallback_started_at(release, key)
    started_at ||= completed_at
    seconds = elapsed_seconds(started_at, completed_at)
    return {} unless seconds

    { duration_seconds: seconds, duration_live: false }
  end

  def release_tracker_duration_bounds(release, key, events)
    steps = case key.to_s
            when "testing" then [["review_tests"]]
            when "assembling" then [["assemble_release"]]
            when "qa_deploying" then [["deploy_qa"]]
            when "confirming" then [%w[ship_gate ship_authorized]]
            when "production_deploying" then [["deploy_prod"]]
            else []
            end
    starts = steps.flatten.filter_map { |step| release_event_at(events, step, "started") }
    finishes = steps.flatten.filter_map { |step| release_event_at(events, step, "completed") }
    started_at = starts.min
    completed_at = finishes.max
    started_at ||= release_tracker_fallback_started_at(release, key) if completed_at
    started_at ||= completed_at if completed_at
    [started_at, completed_at]
  end

  def release_event_at(events, step, status)
    events.select { |event| event.step == step && event.status == status }.map(&:occurred_at).compact.min
  end

  def release_tracker_fallback_started_at(release, key)
    case key.to_s
    when "testing", "assembling" then release.created_at
    when "qa_deploying" then release.assembled_at
    when "confirming" then release.confirmed_at
    when "production_deploying" then release.confirmed_at
    end
  end

  def release_tracker_fallback_completed_at(release, key)
    case key.to_s
    when "assembling" then release.assembled_at
    when "confirming" then release.confirmed_at
    when "production_deploying" then release.shipped_at
    end
  end

  def release_static_duration_label(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60

    "#{seconds / 60}m"
  end

  def release_tracker_step_label(stage, state)
    state.to_sym == :complete ? stage[:complete_label] : stage[:active_label]
  end

  def release_tracker_connector_state(index, done_count)
    if done_count >= RELEASE_TRACKER_STAGES.size
      :complete
    elsif index < done_count - 1
      :complete
    elsif index == done_count - 1
      :active
    else
      :pending
    end
  end

  def release_tracker_done_count(release)
    return RELEASE_TRACKER_STAGES.size if release.shipped?
    return RELEASE_TRACKER_STAGES.size if release_event_done?(release, "deploy_prod")
    return 4 if release_event_done?(release, "ship_gate") ||
                release_event_done?(release, "ship_authorized") ||
                release_event_started?(release, "deploy_prod")
    return 4 if release.confirmed_at.present?
    return 3 if release_event_done?(release, "deploy_qa") ||
                release_event_done?(release, "qa_smoke") ||
                release.state == "assembled"
    return 2 if release_event_done?(release, "assemble_release")
    return 2 if release.qa_url.present? || release_tracker_qa_shas?(release)
    return 1 if release_event_done?(release, "review_tests")
    return 1 if release.tasks.any?

    0
  end

  def release_event_done?(release, step)
    release.respond_to?(:event_completed?) && release.event_completed?(step)
  end

  def release_event_started?(release, step)
    release.respond_to?(:event_started?) && release.event_started?(step)
  end

  def release_tracker_qa_shas?(release)
    shas = release.metadata.is_a?(Hash) ? release.metadata["qa_shas"] : nil
    shas.is_a?(Hash) && shas.values.any?(&:present?)
  end

  def release_tracker_dot_classes(state)
    case state.to_sym
    when :complete then "bg-mint-500 border-mint-300 text-black shadow-sm shadow-mint-900/30"
    when :active   then "bg-amber-300 border-amber-200 text-black ring-4 ring-amber-300/40 shadow-lg shadow-amber-500/40 animate-pulse"
    else                "bg-inset border-subtle text-muted"
    end
  end

  def release_tracker_label_classes(state)
    case state.to_sym
    when :complete then "text-heading"
    when :active   then "text-amber-700 dark:text-amber-200"
    else                "text-muted"
    end
  end

  def release_tracker_connector_classes(state)
    case state.to_sym
    when :complete then "bg-mint-400"
    when :active   then "bg-amber-200/60 dark:bg-amber-300/40 animate-pulse"
    else                "bg-inset"
    end
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

  # The seconds-precision elapsed clock for the ACTIVE Next Release ticker — the
  # SERVER-side initial value the _release_ticker JS then advances every second
  # ("45s" / "7m 23s" / "1h 04m 23s"). Mirrors that JS `fmt()` EXACTLY so the
  # first tick doesn't jump format. `now` is injectable for deterministic tests.
  def release_elapsed_clock(release, now: Time.current)
    format_elapsed_clock(elapsed_seconds(release.created_at, now) || 0)
  end

  # secs → tight H/M/S clock, dropping leading-zero units and zero-padding the
  # trailing ones so the width is stable as it ticks: "45s", "7m 23s",
  # "1h 04m 23s". The single source of truth the JS ticker re-implements.
  def format_elapsed_clock(secs)
    secs = secs.to_i
    return "#{secs}s" if secs < 60

    minutes, seconds = secs.divmod(60)
    return format("%dm %02ds", minutes, seconds) if minutes < 60

    hours, mins = minutes.divmod(60)
    format("%dh %02dm %02ds", hours, mins, seconds)
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

  # Non-stage keys for the release-wide meta-triggers in +devops_kickoffs+ (see
  # below). They never render on column headers — only the current-release
  # section reaches for them.
  AVI_HEARTBEAT_KICKOFF_KEY = "avi_heartbeat"
  AVI_HEARTBEAT_FAST_KICKOFF_KEY = "avi_heartbeat_fast"
  QA_RELEASE_KICKOFF_KEY = "release"
  AUTONOMOUS_RELEASE_KICKOFF_KEY = "release_autonomous"

  # Canonical copy-paste kickoff commands for the DevOps (Deploy) lane — the
  # single source of truth shared by the /deployments column headers, the
  # /stages cards, and the current-release section. The per-stage entries are
  # keyed by DevOps board stage and kept terse (≤3 words) so each fits a column
  # header; the feature-agent lane has none.
  #
  # Plus four non-stage meta-triggers: the slow and fast "Avi Heartbeat" review
  # loops, the QA-only "Build and Deploy QA Release" workflow, and the autonomous
  # "Merge, Assemble, Deploy" workflow. They render as prominent chips in the
  # current-release section, never on column headers, so they are exempt from the
  # per-stage word cap.
  def devops_kickoffs
    {
      AVI_HEARTBEAT_KICKOFF_KEY => "Avi Heartbeat Slow",
      AVI_HEARTBEAT_FAST_KICKOFF_KEY => "Avi Heartbeat Fast",
      QA_RELEASE_KICKOFF_KEY => "Build and Deploy QA Release",
      AUTONOMOUS_RELEASE_KICKOFF_KEY => "Merge, Assemble, Deploy",
      "submitted" => "Review submitted PRs",
      "reviewed"  => "Prepare release",
      "assembled" => "Run Deployment",
      "shipped"   => "Archive completed tasks"
    }
  end

  # The slow "Avi Heartbeat" meta-trigger command — a long-running review
  # supervisor that serializes submitted PR review newest-first, moves approved
  # work to reviewed, and stops with a retrospective after its review cap.
  def avi_heartbeat_kickoff
    devops_kickoffs.fetch(AVI_HEARTBEAT_KICKOFF_KEY)
  end

  def avi_heartbeat_fast_kickoff
    devops_kickoffs.fetch(AVI_HEARTBEAT_FAST_KICKOFF_KEY)
  end

  # The "Build and Deploy QA Release" meta-trigger command — Mr. McRitchie's
  # one-trigger QA-department workflow, surfaced as a prominent chip in the
  # current-release section.
  def qa_release_kickoff
    devops_kickoffs.fetch(QA_RELEASE_KICKOFF_KEY)
  end

  # The autonomous production-release meta-trigger. It follows the same review
  # and QA assembly path as +qa_release_kickoff+, then ships production with the
  # release command's deterministic gates.
  def autonomous_release_kickoff
    devops_kickoffs.fetch(AUTONOMOUS_RELEASE_KICKOFF_KEY)
  end

  def release_kickoff_chips
    [
      { label: "Avi Slow", command: avi_heartbeat_kickoff },
      { label: "Avi Fast", command: avi_heartbeat_fast_kickoff },
      { label: "QA", command: qa_release_kickoff },
      { label: "Prod", command: autonomous_release_kickoff }
    ]
  end

  # The three soul-avatar heartbeat launchers shown in the DevOps card
  # (#release-duration-card on /deployments, tasks/heartbeat_launchers): a soul
  # face (linking to /agents/<slug>) over a
  # PROMPT-LIKE row 1 plus one or more copyable atom acts. Avi's two lanes are now
  # ONE column with two acts. Every row is an INDEPENDENTLY-copyable valid launch
  # prompt. +heartbeat+ (row 1) is the prompt-like soul heartbeat phrase — one per
  # soul ("Avi Heartbeat" / "Steffon Heartbeat" / "Alex Heartbeat"); +acts+ are the
  # launcher atoms that scope that heartbeat's work (Avi: pr-review + production-
  # deploy; Steffon: qa-deploy + archive-completed; Alex: grade-events). +agent_slug+
  # resolves the soul avatar (reused from the heartbeat Agent column + stage
  # timeline) AND its /agents/<slug> link; +label+ is the small purpose caption;
  # +title+ is the hover tooltip. Every row (the heartbeat prompt and each act) is
  # genuinely launchable on its own; each is a recognized launcher in
  # docs/agents/modules/heartbeats.md + qa-release/SKILL.md.
  def heartbeat_launchers
    [
      { agent_slug: "avi",     heartbeat: "Avi Heartbeat",     acts: ["pr-review", "production-deploy"], label: "Review + ship", title: "Avi — review + ship heartbeat" },
      { agent_slug: "steffon", heartbeat: "Steffon Heartbeat", acts: ["qa-deploy", "archive-completed"], label: "QA + archive",   title: "Steffon — QA deploy + archive heartbeat" },
      { agent_slug: "alex",    heartbeat: "Alex Heartbeat",    acts: ["grade-events"],                   label: "Learning",      title: "Alex — grade-events / learning heartbeat" }
    ]
  end

  # One-line "what it does" caption for each heartbeat launcher act, keyed by the
  # act slug used in +heartbeat_launchers+. Sourced from
  # docs/agents/modules/heartbeats.md so the agent profile page can annotate each
  # copyable phrase with the work it launches (Avi: pr-review + production-deploy;
  # Steffon: qa-deploy + archive-completed; Alex: grade-events).
  HEARTBEAT_ACT_DESCRIPTIONS = {
    "pr-review"         => "Review + merge all submitted PRs",
    "production-deploy" => "Ship a QA-ready release to production",
    "qa-deploy"         => "Prepare + deploy to QA (release stages 1–3)",
    "archive-completed" => "Archive completed tasks + releases",
    "grade-events"      => "Grade 10 recent events for quality"
  }.freeze

  def heartbeat_act_description(act)
    HEARTBEAT_ACT_DESCRIPTIONS[act.to_s]
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
          what: "An agent owns the task in an isolated worktree, writing the code and its tests together as the work takes shape.",
          who: "Feature agent", nxt: "Open a PR, pass dor-check --gate merge → submitted" },
        { stage: "blocked",
          what: "Off the pipeline — waiting on an environment fix, QA rework, or a dependency. Records where it stalled (blocked_from) and why (block_kind).",
          who: "Whoever can unblock it (agent for rework, operator for environment)", nxt: "Once cleared, it resumes → back to building or submitted" },
        { stage: "submitted",
          what: "The PR is open and the feature agent's part is done — the seam where Build hands off to DevOps.",
          who: "Feature agent → DevOps", nxt: "DevOps picks it up for review → reviewed" }
      ],
      "Deploy" => [
        { stage: "submitted", kick: devops_kickoffs["submitted"],
          what: "The intake queue — submitted PRs waiting for review. Avi is a THIN delegation gate: he confirms product-acceptance, then picks the two senior reviewers (1 PRIMARY + 1 LIGHT) from {Shannon · Carl · Jasper · Steffon · Alex} via reviewer-select and hands the lane to the PRIMARY — who runs the deep technical review, spawns the LIGHT as its own sub-agent, and owns the rest of the lane.",
          who: "Avi (thin delegate) → PRIMARY reviewer (owns the lane) → LIGHT",
          tests: "Base tier — unit + component. Each senior confirms green, plus code standards, smell, scalability, and acceptance.",
          gate: "Two senior approvals (PRIMARY = Opus on migration / payment / solana / auth). One complete qa_feedback on a fail.",
          nxt: "Two approvals, no blocker → the primary drives to reviewed and runs the merge; one block → rework" },
        { stage: "reviewed",  kick: devops_kickoffs["reviewed"],
          what: "Approved by both reviewers and off the bench — the PRIMARY reviewer runs bin/release merge to land its PR in the persistent release branch (membership flips at merge).",
          who: "The PRIMARY reviewer (owns the lane through the merge)",
          tests: "None re-run — the green review tests carry forward (bias to action: release reverts cleanly, so we don't fear merging there).",
          gate: "Deterministic merge honoring dependencies + lanes; conflicts surface at PR-merge. The primary owns the merge — no separate conductor step.",
          nxt: "Primary runs bin/release merge → assembled; prepare then deploys it to QA" },
        { stage: "assembled", kick: devops_kickoffs["assembled"],
          what: "Every member PR is merged and the release candidate is built; Steffon QAs it and deploys origin/release to QA.",
          who: "Steffon (Platform Engineer)",
          tests: "Integration + an e2e smoke on origin/release (the next tier up from review).",
          gate: "Deterministic suite — a regression blocks the task. No human approval at this step.",
          nxt: "Green → bin/release prepare deploys to QA + a Discord note. The ship decision is at ship, not here" },
        { stage: "shipped",   kick: devops_kickoffs["shipped"],
          what: "Live in production and shown as the board's Last Release; release notes are posted as part of Run Deployment.",
          who: "Avi (tests the frozen SHA) → operator gate or autonomous deploy trigger",
          tests: "Full e2e + highest tier on the FROZEN ship SHA (the exact prod code — fixes 'shipped ≠ tested').",
          gate: "🔒 Build and Deploy QA Release stops for the operator; Merge, Assemble, Deploy grants ship authority after the same gates pass.",
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

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

  def task_stage_count_classes(stage)
    case stage.to_s
    when "designed"  then "bg-blue-900/50 text-blue-300"
    when "building"  then "bg-mint-900/50 text-mint-300"
    when "submitted" then "bg-orange-900/50 text-orange-300"
    when "reviewed"  then "bg-cyan-900/50 text-cyan-300"
    when "assembled" then "bg-violet-900/50 text-violet-300"
    when "shipped"   then "bg-green-900/50 text-green-300"
    when "blocked"   then "bg-red-900/50 text-red-300"
    when "archived"  then "bg-surface-alt text-muted"
    else "bg-surface-alt text-muted"
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
    { key: "production_deploying", active_label: "Deploying Prod", complete_label: "Deployed" }
  ].freeze

  # Pizza-tracker progress for the active release card, derived from the durable
  # writes the conductor already makes during bin/release merge/prepare/ship.
  def release_tracker_steps(release)
    done_count = release_tracker_done_count(release)

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
      )
    end
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
    return 4 if release.confirmed_at.present?
    return 3 if release.state == "assembled"
    return 2 if release.qa_url.present? || release_tracker_qa_shas?(release)
    return 1 if release.tasks.any?

    0
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
  QA_RELEASE_KICKOFF_KEY = "release"
  AUTONOMOUS_RELEASE_KICKOFF_KEY = "release_autonomous"

  # Canonical copy-paste kickoff commands for the DevOps (Deploy) lane — the
  # single source of truth shared by the /deployments column headers, the
  # /stages cards, and the current-release section. The per-stage entries are
  # keyed by DevOps board stage and kept terse (≤3 words) so each fits a column
  # header; the feature-agent lane has none.
  #
  # Plus two non-stage meta-triggers: the QA-only "Build and Deploy QA Release"
  # workflow and the autonomous "Merge, Assemble, Deploy" workflow. They render
  # as prominent chips in the current-release section, never on column headers,
  # so they are exempt from the per-stage word cap.
  def devops_kickoffs
    {
      QA_RELEASE_KICKOFF_KEY => "Build and Deploy QA Release",
      AUTONOMOUS_RELEASE_KICKOFF_KEY => "Merge, Assemble, Deploy",
      "submitted" => "Review submitted PRs",
      "reviewed"  => "Prepare release",
      "assembled" => "Run Deployment",
      "shipped"   => "Archive completed tasks"
    }
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
      { label: "QA", command: qa_release_kickoff },
      { label: "Prod", command: autonomous_release_kickoff }
    ]
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

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

  # The five tracker nodes. Each node derives complete/active/pending purely from
  # the release's stage stamps (Release::STAGES): complete once `completes` is
  # reached, active while `starts` is reached but `completes` is not, pending
  # otherwise. Because a node lights yellow ONLY on its own start stamp, a
  # finished stage leaves the NEXT node dark until its owner posts their start —
  # the explicit Steffon→Avi handoff gap between Live on QA and Confirming.
  RELEASE_TRACKER_STAGES = [
    { key: "testing", active_label: "Testing", complete_label: "Tested",
      starts: "testing", completes: "assembling" },
    { key: "assembling", active_label: "Assembling", complete_label: "Assembled",
      starts: "assembling", completes: "assembled" },
    { key: "qa_deploying", active_label: "Deploying QA", complete_label: "Live on QA",
      starts: "qa_deploying", completes: "qa_deployed" },
    { key: "confirming", active_label: "Confirming", complete_label: "Confirmed",
      starts: "confirming", completes: "confirmed" },
    { key: "production_deploying", active_label: "Deploying", complete_label: "Deployed",
      starts: "prod_deploying", completes: "shipped" }
  ].freeze

  # Pizza-tracker progress for the active release card, read straight off the
  # release's stage stamps (time-and-boolean columns — see Release::STAGES).
  def release_tracker_steps(release, now: Time.current, average_seconds_by_stage: nil)
    average_seconds_by_stage ||= release_tracker_average_seconds_by_stage

    RELEASE_TRACKER_STAGES.each_with_index.map do |stage, index|
      state = release_tracker_state(release, stage)
      stage.merge(
        index: index + 1,
        label: release_tracker_step_label(stage, state),
        state: state,
        connector_state: release_tracker_connector_state(release, index)
      ).merge(
        release_tracker_duration(
          release,
          stage,
          state,
          now: now,
          average: average_seconds_by_stage[stage[:key]]
        )
      )
    end
  end

  def release_tracker_state(release, stage)
    return :complete if release.stage_reached?(stage[:completes])
    return :active if release.stage_reached?(stage[:starts])

    :pending
  end

  # The connector after node `index` takes the state of the node it leads INTO —
  # green behind a complete node, pulsing into the active one, dark into a pending
  # one (including the handoff gap, where finished work meets an unclaimed stage).
  # The terminal node has no outgoing edge (the partial never draws it): its value
  # just mirrors done/not-done so an all-complete tracker reads all-complete.
  def release_tracker_connector_state(release, index)
    next_stage = RELEASE_TRACKER_STAGES[index + 1]
    if next_stage.nil?
      return release_tracker_state(release, RELEASE_TRACKER_STAGES.last) == :complete ? :complete : :pending
    end

    release_tracker_state(release, next_stage)
  end

  # Node timing off the stamps: every REACHED node (active or complete) shows how
  # long ago that stage STARTED — release_ago_label(now → started_at), ticked
  # client-side. started_at is the stage's own start stamp with a lower-bound
  # fallback (stage_started_at_or_before), so a node whose own start event was
  # never posted still reads a sensible "started X ago" instead of blanking. The
  # stage's own span (started → completed) survives as duration_seconds for the
  # tooltip's "took Xm", present only once the stage has finished. A pending node
  # returns {} and renders no timing.
  def release_tracker_duration(release, stage, state, now: Time.current, average: nil)
    return {} if state.to_sym == :pending

    started_at = release.stage_started_at_or_before(stage[:starts])
    own_started_at = release.stage_stamp(stage[:starts])
    completed_at = release.stage_stamp(stage[:completes])
    ago_seconds = elapsed_seconds(started_at, now)
    average_seconds = release_tracker_average_value(average, :average_seconds)
    average_sample_count = release_tracker_average_value(average, :sample_count).to_i

    duration = {
      started_at: started_at,
      ago_seconds: ago_seconds,
      duration_live: state.to_sym == :active,
      completed_at: completed_at,
      # "took" is only real when the stage's OWN start stamp is known — never off
      # the fallback anchor, which would overstate the span from release-open.
      duration_seconds: own_started_at && completed_at ? elapsed_seconds(own_started_at, completed_at) : nil
    }

    if state.to_sym == :active && started_at && average_seconds.to_i.positive?
      duration.merge!(
        average_seconds: average_seconds.to_i,
        average_sample_count: average_sample_count,
        countdown_seconds: average_seconds.to_i - ago_seconds.to_i,
        countdown_label: release_countdown_label(average_seconds: average_seconds, elapsed_seconds: ago_seconds)
      )
    end

    duration
  end

  def release_tracker_average_seconds_by_stage(limit: 3)
    releases = Release.where(state: "shipped")
                      .order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
                      .limit(limit)
                      .to_a

    RELEASE_TRACKER_STAGES.to_h do |stage|
      values = releases.filter_map { |release| release_tracker_stage_span_seconds(release, stage) }
      row = if values.any?
        {
          average_seconds: (values.sum.to_f / values.size).round,
          sample_count: values.size
        }
      end
      [stage[:key], row]
    end
  end

  def release_tracker_stage_span_seconds(release, stage)
    started_at = release.stage_stamp(stage[:starts])
    completed_at = release.stage_stamp(stage[:completes])
    elapsed_seconds(started_at, completed_at) if started_at && completed_at
  end

  def release_tracker_average_value(row, key)
    return nil unless row.is_a?(Hash)

    row[key] || row[key.to_s]
  end

  def release_countdown_label(average_seconds:, elapsed_seconds:)
    remaining = average_seconds.to_i - elapsed_seconds.to_i
    prefix = remaining.negative? ? "-" : ""
    "#{prefix}#{format_elapsed_clock(remaining.abs)}"
  end

  def release_tracker_average_source_label(sample_count)
    count = sample_count.to_i
    return "Historical average" unless count.positive?

    "Last #{count} deployment#{'s' unless count == 1} avg"
  end

  def release_tracker_countdown_title(step)
    remaining = step[:countdown_seconds].to_i
    status = if remaining.negative?
      "over by #{format_elapsed_clock(remaining.abs)}"
    else
      "#{format_elapsed_clock(remaining)} left"
    end

    "#{release_tracker_average_source_label(step[:average_sample_count])}: " \
      "#{format_elapsed_clock(step[:average_seconds])} · elapsed #{format_elapsed_clock(step[:ago_seconds])} · #{status}"
  end

  def release_static_duration_label(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60

    "#{seconds / 60}m"
  end

  # Compact single-unit "X ago" label for a tracker node (time since the stage
  # started). The ago fmt in _release_ticker.html.erb MUST mirror this so the
  # server-rendered value and the first client tick agree.
  def release_ago_label(seconds)
    seconds = seconds.to_i
    return "#{seconds}s ago" if seconds < 60

    minutes = seconds / 60
    return "#{minutes}m ago" if minutes < 60

    # Hourly labels use the standard Hh MMm shape, with seconds dropped.
    hours, mins = minutes.divmod(60)
    format("%dh %02dm ago", hours, mins)
  end

  # Tooltip for a node's started-ago label: the absolute start time, plus the
  # stage's own span once it has finished ("took Xm") so a completed stage's
  # duration is one hover away. An in-flight stage has no span yet, so the
  # tooltip is just its start time.
  def release_tracker_started_title(step)
    started = step[:started_at].in_time_zone.strftime("%b %-d, %-I:%M %p")
    base = "Started #{started}"
    step[:duration_seconds] ? "#{base} · took #{release_static_duration_label(step[:duration_seconds])}" : base
  end

  def release_tracker_step_label(stage, state)
    state.to_sym == :complete ? stage[:complete_label] : stage[:active_label]
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

  RELEASE_MEMBER_HIGHLIGHT_LIMIT = 2
  TASK_SIZE_WEIGHTS = {
    "small"  => 1,
    "medium" => 2,
    "large"  => 3,
    "xl"     => 4
  }.freeze
  TASK_SIZE_LABELS = {
    "small"  => "S",
    "medium" => "M",
    "large"  => "L",
    "xl"     => "XL"
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

  # Current release cards show the two largest member tasks as readable links,
  # then summarize the remaining members by app/repo emoji.
  def release_member_condensed_summary(members, highlight_limit: RELEASE_MEMBER_HIGHLIGHT_LIMIT)
    members = Array(members)
    highlights = release_member_highlights(members, limit: highlight_limit)
    remaining = members.reject { |task| highlights.include?(task) }

    {
      highlights: highlights,
      repo_counts: release_member_repo_counts(remaining)
    }
  end

  def release_member_highlights(members, limit: RELEASE_MEMBER_HIGHLIGHT_LIMIT)
    Array(members).each_with_index
                  .sort_by { |task, index| release_member_expense_sort_key(task, index) }
                  .first(limit)
                  .map(&:first)
  end

  def release_member_repo_counts(tasks)
    Array(tasks).each_with_object({}) do |task, counts|
      task.devops_repositories.each do |repo|
        emoji = app_emoji(repo)
        next if emoji.blank?

        counts[emoji] ||= { emoji: emoji, count: 0, repositories: [] }
        counts[emoji][:count] += 1
        counts[emoji][:repositories] << repo unless counts[emoji][:repositories].include?(repo)
      end
    end.values
  end

  def release_member_expense_weight(task)
    size = release_member_size(task)
    TASK_SIZE_WEIGHTS.fetch(size.to_s, 0)
  end

  def release_member_expense_sort_key(task, index)
    cost = task.total_cost
    return [0, -cost.to_f, index] if cost.to_d.positive?

    [1, -release_member_expense_weight(task), index]
  end

  def release_member_cost_label(task)
    cost = task.total_cost
    return release_member_money_label(cost) if cost.to_d.positive?

    TASK_SIZE_LABELS[release_member_size(task).to_s]
  end

  def release_member_cost_title(task)
    cost = task.total_cost
    return "Measured task cost: #{release_member_money_label(cost)}" if cost.to_d.positive?

    size = release_member_size(task)
    size.present? ? "Estimated task size: #{size.upcase}" : "Task cost not measured"
  end

  def release_member_size(task)
    [task.actual_size, task.dev_size, task.po_size].find(&:present?)
  end

  def release_member_money_label(cost)
    value = cost.to_f
    return "$0.00" if value < 0.001

    value < 1 ? format("$%.4f", value) : format("$%.2f", value)
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
  # the soul heartbeat launchers in +heartbeat_launchers+ (Avi gains pr-review-slow;
  # Alex gains the full-cycle act that carries the former Merge/Assemble/Deploy).
  def devops_kickoffs
    {
      "submitted" => "Review submitted PRs",
      "reviewed"  => "Prepare release",
      "assembled" => "Run Deployment",
      "shipped"   => "Archive completed tasks"
    }
  end

  # The three soul-avatar heartbeat launchers shown on the standalone Heartbeats
  # card (tasks/_heartbeats_card on /deployments, one tasks/_heartbeat_launcher
  # per soul): a soul face (linking to /agents/<slug>) over a
  # PROMPT-LIKE row 1 plus one or more copyable atom acts. Every row is an
  # INDEPENDENTLY-copyable valid launch
  # prompt. +heartbeat+ (row 1) is the prompt-like soul heartbeat phrase — one per
  # soul ("Avi Heartbeat" / "Steffon Heartbeat" / "Alex Heartbeat"); +actions+ are
  # the launcher acts that scope that heartbeat's work (Avi: production-deploy +
  # pr-review + pr-review-slow; Steffon: archive-shipped + qa-release; Alex:
  # grade-events + share-insights + full-cycle). +agent_slug+
  # resolves the soul avatar (reused from the heartbeat Agent column + stage
  # timeline) AND its /agents/<slug> link; +label+ is the small purpose caption;
  # +title+ is the hover tooltip. Every row (the heartbeat prompt and each act) is
  # genuinely launchable on its own; each is a recognized launcher in
  # docs/agents/modules/heartbeats.md + the per-agent HEARTBEAT.md launchers.
  def heartbeat_launchers
    [
      { agent_slug: "avi",     heartbeat: "Avi Heartbeat",     actions: ["production-deploy", "pr-review", "pr-review-slow", "deploy-with-task"], label: "Ship + review", title: "Avi — ship a ready release, then review new PRs" },
      { agent_slug: "steffon", heartbeat: "Steffon Heartbeat", actions: ["archive-shipped", "qa-release"],                  label: "Archive + QA",  title: "Steffon — archive shipped work, then QA the release" },
      { agent_slug: "alex",    heartbeat: "Alex Heartbeat",    actions: ["grade-events", "share-insights", "full-cycle"], label: "Learn + ship",  title: "Alex — grade, share insights, + full DevOps cycle heartbeat" }
    ]
  end

  # One-line "what it does" caption for each heartbeat launcher act, keyed by the
  # act slug used in +heartbeat_launchers+. Sourced from
  # docs/agents/modules/heartbeats.md so the agent profile page can annotate each
  # copyable phrase with the work it launches — one caption per act registered in
  # +heartbeat_launchers+.
  ACTION_DESCRIPTIONS = {
    "pr-review"         => "Review all submitted PRs (review-only — Steffon sweeps)",
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
  # acts get a 1→4 keycap so the buttons read as a sequence across the souls (Avi
  # pr-review 1 → Steffon qa-release 2 → Avi production-deploy 3 → Steffon
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
          nxt: "Two approvals, no blocker → the PRIMARY drives to reviewed; one block → rework" },
        { stage: "reviewed",  kick: devops_kickoffs["reviewed"],
          what: "Approved by both reviewers and ready for Steffon's self-healing qa-release sweep, which merges reviewed PRs onto the persistent release branch and flips members only after QA-green.",
          who: "Steffon (Platform Engineer)",
          tests: "Integration + an e2e smoke on origin/release before QA deploy; review's green base tests carry forward.",
          gate: "Deterministic sweep honoring dependencies + lanes; conflicts surface at PR-merge and block only the affected task.",
          nxt: "Steffon runs bin/release prepare → QA deploy → assembled on QA-green" },
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
          gate: "🔒 Steffon's qa-release stops for the operator at QA; Avi's production-deploy (or the Alex full-cycle) grants ship authority after the same gates pass.",
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

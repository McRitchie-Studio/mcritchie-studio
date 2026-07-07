# Display helpers for the Alex learning-heartbeat activity table — pure label /
# palette / formatter functions, kept here (not in the view) so they unit-test in
# isolation. The table itself is read-only; nothing here mutates an AgentAction.
module HeartbeatHelper
  # Actor lane -> human description (mirrors AgentAction's actor constants). The
  # cell shows the short slug; this is surfaced via `title` on hover.
  HEARTBEAT_ACTOR_DESCRIPTIONS = {
    "harness" => "Claude Code / Codex runtime",
    "agent"   => "The session agent (on-policy)",
    "board"   => "Rails board / bin command",
    "human"   => "The operator (Mr. McRitchie)"
  }.freeze

  # Stage -> { label, description, accent } for the group header chip + its
  # tooltip. A null/blank stage is the pre-task "Session" phase (boot + intake),
  # the real-data analog of the prototype's opening phases — it sorts to the top.
  HEARTBEAT_STAGE_META = {
    nil         => { label: "Session",   accent: "#8b949e",
                     description: "Pre-task — session boot, recall, and intake (no task yet)" },
    "designed"  => { label: "Designed",  accent: "#58a6ff",
                     description: "Designing — shaping the task, acceptance, and worktree" },
    "building"  => { label: "Building",  accent: "#fb923c",
                     description: "Building — exploring, editing, and testing the code" },
    "submitted" => { label: "Submitted", accent: "#a371f7",
                     description: "Submitting — full-suite, PR, and handoff at the seam" },
    "reviewed"  => { label: "Reviewed",  accent: "#7ee787",
                     description: "Reviewed — senior QA verdict recorded" },
    "assembled" => { label: "Assembled", accent: "#d29922",
                     description: "Assembled — merged into release, staged for QA" },
    "shipped"   => { label: "Shipped",   accent: "#3fb950",
                     description: "Shipped — release fast-forwarded to main" },
    "blocked"   => { label: "Blocked",   accent: "#f85149",
                     description: "Blocked — needs attention before it can move" },
    "archived"  => { label: "Archived",  accent: "#5c6573",
                     description: "Archived — terminal" }
  }.freeze

  # Action result -> badge metadata (the local credit signal). Drives the Result
  # badge AND the row's left-edge accent, the read-only analog of the prototype's
  # disposition edge.
  HEARTBEAT_OUTCOME_META = {
    "ok"      => { label: "ok",      color: "#3fb950" },
    "error"   => { label: "error",   color: "#f85149" },
    "pending" => { label: "pending", color: "#6e7681" }
  }.freeze

  # Category -> { accent, description } for an AgentActivity badge + tooltip.
  # These are the agent-declared activity vocabulary (AgentActivity::CATEGORIES).
  HEARTBEAT_CATEGORY_META = {
    "Explore"  => { accent: "#58a6ff", description: "Explore — read, grep, and locate the seam" },
    "Edit"     => { accent: "#fb923c", description: "Edit — write or change the code" },
    "Verify"   => { accent: "#3fb950", description: "Verify — run tests and checks" },
    "Version"  => { accent: "#a371f7", description: "Version — commit, branch, and push" },
    "Workflow" => { accent: "#d29922", description: "Workflow — board, task, and process steps" },
    "Delegate" => { accent: "#f778ba", description: "Delegate — hand an activity to a sub-agent" },
    "Clarify"  => { accent: "#7ee787", description: "Clarify — intake, triage, and questions" },
    "Remote"   => { accent: "#79c0ff", description: "Remote — network, API, and remote ops" },
    "Research" => { accent: "#ffa657", description: "Research — web, docs, and reference lookup" },
    "Plan"     => { accent: "#a5d6ff", description: "Plan — shape the approach and the steps" }
  }.freeze

  # The read-only label for an unlabeled group — raw tool-calls the agent never
  # narrated into an activity (a null agent_activity_id). Kept as one constant so the
  # view, the badge, and any tests read the same string.
  HEARTBEAT_UNLABELED = { accent: "#5c6573", description: "Unlabeled — context the agent did not narrate into an activity" }.freeze

  def heartbeat_category_meta(category)
    HEARTBEAT_CATEGORY_META.fetch(category.to_s) do
      { accent: "#8b949e", description: category.to_s }
    end
  end

  def heartbeat_stage_meta(stage)
    HEARTBEAT_STAGE_META.fetch(stage.presence) do
      { label: stage.to_s.titleize, accent: "#8b949e", description: stage.to_s.titleize }
    end
  end

  def heartbeat_actor_description(actor)
    HEARTBEAT_ACTOR_DESCRIPTIONS[actor.to_s].presence || actor.to_s
  end

  def heartbeat_outcome_meta(outcome)
    HEARTBEAT_OUTCOME_META[outcome.to_s] || { label: outcome.to_s, color: "#6e7681" }
  end

  # The test-scope registry (config/devops_test_suites.yml) — the SINGLE source
  # for a test-scope run's phase/tier/host. It MERGES all three scope sections so
  # the band enriches release runs (`release_scopes:`, bin/release), local cert runs
  # (`full_suite_scopes:`, bin/full-suite-check), AND ingested CI runs (`ci_scopes:`,
  # bin/ci-scope-capture) alike; their keys are distinct (release_/full_suite_/ci_),
  # so a collision never arises today. The Test-runs band DERIVES this metadata at
  # render from the run's event_slug (the scope key) so it is never stored on the
  # action and never drifts when a scope is re-tiered. Memoized per process; a
  # missing/malformed file degrades to {} so a run row still renders (just without
  # the meta chips). Mirrors bin/release.rb's own TEST_SCOPES reader — the registry
  # describes, it never gates.
  RELEASE_SCOPES =
    begin
      cfg = YAML.load_file(Rails.root.join("config/devops_test_suites.yml")) || {}
      cfg.fetch("full_suite_scopes", {})
         .merge(cfg.fetch("release_scopes", {}))
         .merge(cfg.fetch("ci_scopes", {}))
    rescue StandardError
      {}
    end

  # The {phase, tier, host, blocks, mutates} metadata for a scope key (string
  # keys), or {} when the key is unregistered — a run whose scope was renamed
  # still renders, just without derived chips.
  def heartbeat_release_scope_meta(scope_key)
    RELEASE_SCOPES[scope_key.to_s] || {}
  end

  # Re-extract the recognizable test-count segment from a test-scope run's summary
  # ("141 runs, 320 assertions, 0 failures, 0 errors", "12 passed, 2 failed",
  # "http 200"), or nil. The counts are NOT a stored column — the emit folds them
  # into the summary string — so the band re-reads them here with the SAME shapes
  # bin/release.rb's parse_test_counts produces. Blank-safe.
  def heartbeat_test_scope_counts(summary)
    text = summary.to_s
    return Regexp.last_match(0) if text =~ /\d+ runs?, \d+ assertions?, \d+ failures?, \d+ errors?/
    return Regexp.last_match(0) if text =~ /\d+ passed(?:, \d+ failed)?/
    return Regexp.last_match(0) if text =~ /http \d{3}/

    nil
  end

  # Compact human duration for a test-scope run from its stored duration_ms
  # ("1.2s", "830ms"), or nil when unmeasured. duration_ms is the authoritative
  # column (the emit sends elapsed*1000), so the band reads it directly rather
  # than re-parsing the summary string.
  def heartbeat_duration(duration_ms)
    ms = duration_ms.to_i
    return nil unless ms.positive?

    ms >= 1000 ? "#{(ms / 1000.0).round(1)}s" : "#{ms}ms"
  end

  # Short model label for the dense cell ("claude-opus-4-8" -> "opus-4-8"); the
  # full id is surfaced via `title` on hover. Drops a leading vendor prefix and a
  # trailing tier suffix like "[1m]" so the cell stays narrow.
  def heartbeat_model_short(model)
    return "—" if model.blank?

    model.to_s.sub(/\Aclaude-/, "").sub(/\[[^\]]*\]\z/, "")
  end

  # Compact token count: 9_400 -> "9.4k", 360 -> "360".
  def heartbeat_tokens_compact(count)
    count = count.to_i
    return count.to_s if count < 1000

    "#{(count / 1000.0).round(1)}k"
  end

  # "in/out" token pair for the Tokens cell, or "—" when the action spent none
  # (board/harness steps carry no model usage).
  def heartbeat_tokens(action)
    heartbeat_tokens_pair(action.tokens_in, action.tokens_out)
  end

  # The same "in/out" pair from raw counts rather than an action — the aggregated
  # form the activity row uses (summed across an activity's rolled-up actions).
  # "—" when the activity spent nothing (pure board/harness steps carry no usage).
  def heartbeat_tokens_pair(tokens_in, tokens_out)
    ti = tokens_in.to_i
    to = tokens_out.to_i
    return "—" if ti.zero? && to.zero?

    "#{heartbeat_tokens_compact(ti)}/#{heartbeat_tokens_compact(to)}"
  end

  # Sum token + cost usage across actions, DEDUPED by source_turn_uuid. One
  # assistant turn can fire N parallel tool calls (N actions that all carry THAT
  # turn's usage), so a naive per-action sum multi-counts the fan-out. Counting
  # each distinct turn once fixes it. Actions with a blank source_turn_uuid are
  # pre-usage / board / harness rows with no shared turn — each counts on its own.
  # Tokens summed here are the FRESH spend (tokens_in/out) — cache_read is priced
  # into `cost` but never added to the displayed token count. Pure in-memory
  # reduction over the array the controller already loaded (no query per row).
  # Returns summed in/out tokens, their total, and summed cost.
  def heartbeat_usage_totals(actions)
    seen = {}
    tokens_in = 0
    tokens_out = 0
    cost = 0.0
    Array(actions).each do |action|
      turn = action.source_turn_uuid.presence
      next if turn && seen.key?(turn)

      seen[turn] = true if turn
      tokens_in  += action.tokens_in.to_i
      tokens_out += action.tokens_out.to_i
      cost       += action.cost.to_f
    end
    { tokens_in: tokens_in, tokens_out: tokens_out,
      tokens_total: tokens_in + tokens_out, cost: cost }
  end

  # The tooltip surfaced on a per-action tokens/cost cell that INHERITS its turn's
  # spend (a non-primary row of a shared source_turn_uuid). One assistant turn is
  # metered once, so its fan-out of tool-calls repeat that spend verbatim; the
  # tooltip tells the operator the number is shared, not additive.
  SHARED_TURN_TITLE = "shared with this turn's first action"

  def heartbeat_shared_turn_title
    SHARED_TURN_TITLE
  end

  # The ids of the actions whose tokens/cost DUPLICATE their turn's first action.
  # Usage is metered per assistant TURN, not per tool-call: N tool-calls from one
  # turn each carry that turn's usage and render IDENTICAL tokens/cost (they share
  # a source_turn_uuid), which reads like double-counting. Walking the session's
  # actions in chronological order (occurred_at then seq — the order the controller
  # already loads @actions in), the FIRST action of each source_turn_uuid is the
  # PRIMARY and keeps its normal color; every SUBSEQUENT action sharing that turn
  # is a duplicate whose id lands here, so the view fades its tokens/cost cells to
  # signal the spend is inherited. Exactly ONE primary per turn across the WHOLE
  # session, even when a turn's calls land under different activities. Actions with a
  # blank source_turn_uuid are each their own primary and never appear here.
  # Display-only — mirrors the dedupe in heartbeat_usage_totals, changes NO value.
  def heartbeat_shared_turn_ids(actions)
    seen = {}
    Array(actions).each_with_object(Set.new) do |action, dups|
      turn = action.source_turn_uuid.presence
      next unless turn

      if seen[turn]
        dups << action.id
      else
        seen[turn] = true
      end
    end
  end

  # Activity-row totals. New activity spans report their own measured close-diff
  # model/tokens/cost; those numbers are authoritative and deliberately do NOT fall
  # back to parent action usage. The legacy one-arg form still aggregates actions for
  # raw-action contexts. `mascot` is the most common action mascot, a fallback the
  # view uses only when the activity carries no mascot of its own.
  def heartbeat_activity_totals(activity_or_actions, actions = nil)
    activity = actions.nil? ? nil : activity_or_actions
    actions = Array(actions.nil? ? activity_or_actions : actions)
    mascot = heartbeat_dominant(actions.map(&:mascot))

    if activity&.respond_to?(:measured_usage?) && activity.measured_usage?
      tokens_in = activity.tokens_in.to_i
      tokens_out = activity.tokens_out.to_i
      return {
        tokens_in: tokens_in,
        tokens_out: tokens_out,
        tokens_total: tokens_in + tokens_out,
        cost: activity.cost.to_f,
        model: activity.model,
        mascot: mascot
      }
    end

    return { tokens_in: 0, tokens_out: 0, tokens_total: 0, cost: 0.0,
             model: nil, mascot: mascot } if activity

    totals = heartbeat_usage_totals(actions)
    {
      tokens_in:    totals[:tokens_in],
      tokens_out:   totals[:tokens_out],
      tokens_total: totals[:tokens_total],
      cost:         totals[:cost],
      model:        heartbeat_dominant(actions.map(&:model)),
      mascot:       mascot
    }
  end

  # The most frequent non-blank value in a list (the activity's dominant model/mascot),
  # or nil when the list is empty/all-blank. Ties resolve to the first-seen value.
  def heartbeat_dominant(values)
    values.filter_map { |v| v.to_s.presence }
          .tally
          .max_by { |_value, count| count }
          &.first
  end

  # Cost formatter mirroring the prototype: zero -> "—", sub-cent -> "$0.00",
  # sub-dollar -> 4dp (so fractions of a cent still read), else 2dp.
  def heartbeat_cost(cost)
    cents = cost.to_f
    return "—" if cents <= 0
    return "$0.00" if cents < 0.001

    cents < 1 ? format("$%.4f", cents) : format("$%.2f", cents)
  end

  # Whitespace-delimited word count for the drawer's live "aim 4-7 words" counter —
  # the server-rendered initial value the Alpine counter then keeps in sync. Mirrors
  # the prototype's `words()` (trim, split on runs of whitespace, drop blanks).
  def heartbeat_word_count(text)
    text.to_s.strip.split(/\s+/).reject(&:empty?).length
  end

  # The close-side of an activity on the activity-grouped heartbeat: the narrated
  # outcome_slug when the agent closed it, or the "…in progress" placeholder while
  # the activity is still OPEN (open? / no outcome). Read-only display only.
  IN_PROGRESS = "…in progress"

  def heartbeat_activity_result(activity)
    return IN_PROGRESS if activity.open? || activity.outcome_slug.blank?

    activity.outcome_slug
  end

  # An activity's lifecycle badge for the Status column — the distinct signal the operator
  # asked for so an OPEN activity reads as legitimately in-progress, not a hung/broken
  # row. "open" is amber (still running); "done" is a quiet slate (closed), kept
  # deliberately NOT green so it never reads as a "good" grade verdict.
  HEARTBEAT_ACTIVITY_STATUS = {
    open: { label: "open", color: "#d29922" },
    done: { label: "done", color: "#8b949e" }
  }.freeze
  HEARTBEAT_SPAN_STATUS = HEARTBEAT_ACTIVITY_STATUS

  # An activity's Status/Task badge. When the activity's task changed STAGE during the activity's
  # window, the badge becomes that target stage — humanized + colored with the SAME
  # board palette /tasks and /deployments use (Task::STAGE_LABELS + stage_scheme +
  # the components/badge pill), so a stage-change activity reads as its new stage instead
  # of the generic "done". `stage_transitions` is the controller's bulk map
  # { task_slug => [chronological transition TaskEvents] }; when it is empty (no
  # task_slug, no transitions loaded) this falls straight back to the open/done badge,
  # so the helper is safe to call with no map (the drawer/isolated renders do).
  def heartbeat_activity_status_meta(activity, stage_transitions = {})
    if (to_stage = heartbeat_activity_stage_change(activity, stage_transitions))
      return {
        stage:  to_stage,
        label:  Task::STAGE_LABELS.fetch(to_stage, to_stage.to_s.humanize),
        scheme: stage_scheme(to_stage)
      }
    end

    HEARTBEAT_ACTIVITY_STATUS[activity.open? ? :open : :done]
  end

  # The stage an activity's task CHANGED TO during the activity's window, or nil. An activity
  # badges as a stage change when a kind:"transition" TaskEvent for the activity's
  # task_slug lands inside [opened_at, closed_at] (an OPEN activity's window runs to
  # now); the LAST such transition wins. `stage_transitions` is the pre-grouped
  # bulk map { task_slug => [chronological transitions] } — a blank slug / no
  # transitions returns nil, so this never triggers a per-row query.
  def heartbeat_activity_stage_change(activity, stage_transitions = {})
    slug = activity.task_slug.presence
    return nil if slug.blank? || activity.opened_at.blank?

    transitions = (stage_transitions || {})[slug]
    return nil if transitions.blank?

    window_end = activity.closed_at || Time.current
    transitions.select { |te| te.occurred_at >= activity.opened_at && te.occurred_at <= window_end }
               .last&.to_stage
  end

  # Render an activity's status badge from its status meta. A stage-change activity renders
  # the shared board badge pill (components/badge — exact /tasks + /deployments
  # look, both themes) wrapped in the stable event-status test hook; every other
  # activity keeps the lightweight open/done outcome chip. One code path for the table
  # AND the drawer so they never drift.
  def heartbeat_activity_status_badge(status)
    if status[:stage].present?
      tag.span(render("components/badge", text: status[:label], scheme: status[:scheme]),
               class: "hb-outcome-badge", data: { test: "event-status", stage: status[:stage] })
    else
      tag.span(status[:label], class: "hb-outcome", data: { test: "event-status" },
               style: "color: #{status[:color]}")
    end
  end

  alias_method :heartbeat_event_totals, :heartbeat_activity_totals
  alias_method :heartbeat_event_outcome, :heartbeat_activity_result
  alias_method :heartbeat_span_status_meta, :heartbeat_activity_status_meta
  alias_method :heartbeat_span_stage_change, :heartbeat_activity_stage_change
  alias_method :heartbeat_span_status_badge, :heartbeat_activity_status_badge

  # Short, dense timestamp for the "Opened" cell ("Jun 30, 14:07"); the full
  # timestamp rides along in the cell's title. Blank-safe so an activity missing an
  # opened_at still renders a dash rather than raising.
  def heartbeat_time(time)
    return "—" if time.blank?

    time.strftime("%b %-d, %H:%M")
  end

  # The SECOND-precision timestamp ("Jul 6, 19:24:11") — the observability view wants
  # the finish/start time down to the second, not the minute-truncated heartbeat_time.
  # The underlying datetime columns store microsecond precision, so the seconds are
  # already persisted; this is purely the render. Blank-safe.
  def heartbeat_time_seconds(time)
    return "—" if time.blank?

    time.strftime("%b %-d, %H:%M:%S")
  end

  # The bare wall-clock ("19:28:22") — the END side of an action's created→completed
  # span, where the full date already rode along on the "created at" start. Blank-safe.
  def heartbeat_clock(time)
    return "—" if time.blank?

    time.strftime("%H:%M:%S")
  end

  # A live elapsed count formatted "H:MM:SS" (or "M:SS" under an hour) — the
  # server-rendered initial value for an OPEN activity's ticking timer (hbElapsed
  # then keeps it in sync client-side) AND the closed-activity fallback. Negative /
  # nil degrades to "0:00" rather than raising.
  def heartbeat_elapsed(total_seconds)
    secs = total_seconds.to_i
    secs = 0 if secs.negative?
    hours = secs / 3600
    minutes = (secs % 3600) / 60
    seconds = secs % 60
    if hours.positive?
      format("%d:%02d:%02d", hours, minutes, seconds)
    else
      format("%d:%02d", minutes, seconds)
    end
  end

  # An action's COMPLETED-at time, derived from its start plus how long it ran:
  # occurred_at (the created/started stamp) + duration_ms. Returns nil when the
  # action carries no positive duration — the live PostToolUse capture records a
  # single instant (no elapsed), so most tool-calls have only a "created at" and no
  # distinct completion. Blank/negative-safe.
  def heartbeat_action_completed_at(action)
    started = action.occurred_at
    ms = action.duration_ms.to_i
    return nil if started.blank? || ms <= 0

    started + (ms / 1000.0).seconds
  end

  # The action row's created→completed SPAN in the exact operator-specified format:
  #   "created at Jul 6, 19:24:11 - completed at 19:28:22"
  # (full date+seconds on the start, bare wall-clock on the end). An action with no
  # measured duration has no distinct completion, so it renders just the created
  # side ("created at Jul 6, 19:24:11"). Blank-safe → "—".
  def heartbeat_action_span(action)
    started = action.occurred_at
    return "—" if started.blank?

    span = "created at #{heartbeat_time_seconds(started)}"
    completed = heartbeat_action_completed_at(action)
    span += " - completed at #{heartbeat_clock(completed)}" if completed
    span
  end

  # Compact preview of a raw tool-call's input for the drill-down ("kind/input"),
  # single-lined and clipped so a long bash command or file body stays one dense
  # row. Full value is surfaced via the cell title.
  def heartbeat_input_preview(input, limit: 120)
    text = input.to_s.strip.gsub(/\s+/, " ")
    return "—" if text.blank?

    text.length > limit ? "#{text[0, limit]}…" : text
  end

  # The compact "Agent" cell — a tight vertical stack of "small avatar + NAME" rows
  # (the original 📋 Avi / ✦ Magikarp text layout, but with the real avatar image in
  # place of the emoji). The acting SOUL (AgentActivity#agent) rides ON TOP — bold, in
  # its own tint — over the base session mascot BENEATH it (muted). The name is
  # VISIBLE beside each face (not just a hover title) so a glance reads WHO acted.
  # Most rows carry no acting soul (a nil agent) and collapse to a SINGLE mascot row
  # (avatar + name on one line); a row with neither renders an em dash. The soul
  # reuses the seeded Agent record (avatar image, deterministic initials fallback,
  # name + status_color tint), falling back to a titleized-slug stand-in when the
  # Agent isn't seeded; the base mascot wraps the seeded Pokémon in the shared
  # MascotAgent bridge (sprite image, single-letter fallback) so it drops straight
  # into agent_avatar. `agent`/`pokemon` are the records the controller pre-loaded in
  # one query each (nil-safe) — this adds NO query (MascotAgent takes a nil color so
  # signature_color is never hit per row). `submascot` dims the mascot on the
  # drill-down rows; `mascot_test` stamps the base mascot's data-test hook (e.g.
  # "event-mascot"). Faces are the compact agent_avatar "xxs" (24px) size.
  def heartbeat_agent_cell(mascot_slug: nil, pokemon: nil, agent_slug: nil, agent: nil,
                           supervisor_slug: nil, supervisor: nil, show_mascot: true,
                           submascot: false, mascot_test: nil, size: "xxs")
    mascot_slug = mascot_slug.presence
    agent_slug  = agent_slug.presence
    supervisor_slug = supervisor_slug.presence
    mascot_name = pokemon&.name.presence || mascot_slug&.titleize
    soul = (agent || Agent.new(slug: agent_slug, name: agent_slug.titleize)) if agent_slug
    supervisor_soul = (supervisor || Agent.new(slug: supervisor_slug, name: supervisor_slug.titleize)) if supervisor_slug

    entries = []
    if agent_slug
      entries << {
        name: soul.name,
        face: tag.span(render(partial: "components/agent_avatar", locals: { agent: soul, size: size }),
                       class: "hb-ava hb-soulava", style: "color: #{soul.status_color}",
                       title: soul.name, data: { test: "agent-soul", soul: agent_slug })
      }
    end
    if supervisor_slug
      entries << {
        name: supervisor_soul.name,
        face: tag.span(render(partial: "components/agent_avatar", locals: { agent: supervisor_soul, size: size }),
                       class: "hb-ava hb-supervisorava", style: "color: #{supervisor_soul.status_color}",
                       title: supervisor_soul.name,
                       data: { test: "agent-supervisor", supervisor: supervisor_slug })
      }
    end
    if show_mascot && mascot_slug
      face = StageAgentsHelper::MascotAgent.new(name: mascot_name, avatar: pokemon&.sprite_url, color: nil)
      entries << {
        name: mascot_name,
        face: tag.span(render(partial: "components/agent_avatar", locals: { agent: face, size: size }),
                       class: class_names("hb-ava", "hb-mascotava",
                                          "hb-submascot" => submascot || agent_slug.present? || supervisor_slug.present?),
                       title: mascot_name, data: mascot_test ? { test: mascot_test } : {})
      }
    end

    return tag.span("—", class: "hb-meta") if entries.empty?

    avatars = tag.div(safe_join(entries.map { |entry| entry[:face] }), class: "hb-avatars")

    names = entries.each_with_index.map do |entry, index|
      tag.span(entry[:name], class: index.zero? ? "hb-nameprimary" : "hb-namesub")
    end
    name_col = tag.div(safe_join(names), class: "hb-names")

    tag.div(safe_join([avatars, name_col]),
            class: class_names("hb-agentstack", "hb-solo" => agent_slug.nil? && supervisor_slug.nil?),
            data: { test: "agent-stack" })
  end

  # Pretty-print a captured tool-call payload for the drill-down drawer. Input and
  # output are stored as raw (often escaped) JSON strings, so a nested `content`
  # field reads as one `\n`-laden line. Parse and re-emit with 2-space indent so the
  # STRUCTURE expands across lines, then unescape the newlines/tabs JSON re-escapes
  # inside string values so a multi-line file body or command reads as REAL line
  # breaks rather than literal `\n`. Falls back to the raw string UNTOUCHED when the
  # payload is not valid JSON (a bash command, a plain sentence) so the view never
  # raises. Blank-safe. Display-only: the result is intentionally no longer strict
  # JSON — readability for the operator wins over round-trippability here.
  def heartbeat_pretty_json(raw)
    text = raw.to_s
    return text if text.blank?

    pretty = JSON.pretty_generate(JSON.parse(text))
    pretty.gsub('\n', "\n").gsub('\t', "\t")
  rescue JSON::ParserError
    text
  end
end

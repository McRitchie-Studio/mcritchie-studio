# Display helpers for the Alex learning-heartbeat trajectory table — pure label /
# palette / formatter functions, kept here (not in the view) so they unit-test in
# isolation. The table itself is read-only; nothing here mutates an AtomicAction.
module HeartbeatHelper
  # Actor lane -> human description (mirrors AtomicAction's actor constants). The
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

  # Outcome -> badge metadata (the local credit signal). Drives the Outcome cell
  # badge AND the row's left-edge accent, the read-only analog of the prototype's
  # disposition edge.
  HEARTBEAT_OUTCOME_META = {
    "ok"      => { label: "ok",      color: "#3fb950" },
    "error"   => { label: "error",   color: "#f85149" },
    "pending" => { label: "pending", color: "#6e7681" }
  }.freeze

  # Category -> { accent, description } for an AtomicEvent span's badge + tooltip.
  # These are the agent-declared span vocabulary (AtomicEvent::CATEGORIES); the
  # accent tints the span badge and its left-edge on the event-grouped heartbeat.
  # Distinct, readable-on-dark hues so a glance separates the ten span kinds.
  HEARTBEAT_CATEGORY_META = {
    "Explore"  => { accent: "#58a6ff", description: "Explore — read, grep, and locate the seam" },
    "Edit"     => { accent: "#fb923c", description: "Edit — write or change the code" },
    "Verify"   => { accent: "#3fb950", description: "Verify — run tests and checks" },
    "Version"  => { accent: "#a371f7", description: "Version — commit, branch, and push" },
    "Workflow" => { accent: "#d29922", description: "Workflow — board, task, and process steps" },
    "Delegate" => { accent: "#f778ba", description: "Delegate — hand a span to a sub-agent" },
    "Clarify"  => { accent: "#7ee787", description: "Clarify — intake, triage, and questions" },
    "Remote"   => { accent: "#79c0ff", description: "Remote — network, API, and remote ops" },
    "Research" => { accent: "#ffa657", description: "Research — web, docs, and reference lookup" },
    "Plan"     => { accent: "#a5d6ff", description: "Plan — shape the approach and the steps" }
  }.freeze

  # The read-only label for an unlabeled group — raw tool-calls the agent never
  # narrated into a span (a null atomic_event_id). Kept as one constant so the
  # view, the badge, and any tests read the same string.
  HEARTBEAT_UNLABELED = { accent: "#5c6573", description: "Unlabeled — context the agent did not narrate into a span" }.freeze

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
  # form the EVENT row uses (summed across a span's rolled-up actions). "—" when
  # the span spent nothing (a span of pure board/harness steps carries no usage).
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
  # session, even when a turn's calls land under different spans. Actions with a
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

  # Roll a span's attributed actions up into the totals the EVENT row shows: summed
  # in/out tokens, summed cost (all DEDUPED by source_turn_uuid, see above), and the
  # span's dominant model (the model most of its actions ran on). Pure aggregation
  # over the in-memory array the controller already loaded under each span
  # (@event_rows), so the event table adds NO query per row — the N+1 the task
  # explicitly forbids. `mascot` is the most common action mascot, a fallback the
  # view uses only when the span carries no mascot of its own.
  def heartbeat_event_totals(actions)
    actions = Array(actions)
    totals  = heartbeat_usage_totals(actions)
    {
      tokens_in:    totals[:tokens_in],
      tokens_out:   totals[:tokens_out],
      tokens_total: totals[:tokens_total],
      cost:         totals[:cost],
      model:        heartbeat_dominant(actions.map(&:model)),
      mascot:       heartbeat_dominant(actions.map(&:mascot))
    }
  end

  # The most frequent non-blank value in a list (the span's dominant model/mascot),
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

  # The close-side of a span on the event-grouped heartbeat: the narrated
  # outcome_slug when the agent closed it, or the "…in progress" placeholder while
  # the span is still OPEN (open? / no outcome). Read-only display only.
  IN_PROGRESS = "…in progress"

  def heartbeat_event_outcome(event)
    return IN_PROGRESS if event.open? || event.outcome_slug.blank?

    event.outcome_slug
  end

  # A span's lifecycle badge for the Status column — the distinct signal the operator
  # asked for so an OPEN span reads as legitimately in-progress, not a hung/broken
  # row. "open" is amber (still running); "done" is a quiet slate (closed), kept
  # deliberately NOT green so it never reads as a "good" grade verdict.
  HEARTBEAT_SPAN_STATUS = {
    open: { label: "open", color: "#d29922" },
    done: { label: "done", color: "#8b949e" }
  }.freeze

  # A span's Status/Task badge. When the span's task changed STAGE during the span's
  # window, the badge becomes that target stage — humanized + colored with the SAME
  # board palette /tasks and /deployments use (Task::STAGE_LABELS + stage_scheme +
  # the components/badge pill), so a stage-change span reads as its new stage instead
  # of the generic "done". `stage_transitions` is the controller's bulk map
  # { task_slug => [chronological transition TaskEvents] }; when it is empty (no
  # task_slug, no transitions loaded) this falls straight back to the open/done badge,
  # so the helper is safe to call with no map (the drawer/isolated renders do).
  def heartbeat_span_status_meta(event, stage_transitions = {})
    if (to_stage = heartbeat_span_stage_change(event, stage_transitions))
      return {
        stage:  to_stage,
        label:  Task::STAGE_LABELS.fetch(to_stage, to_stage.to_s.humanize),
        scheme: stage_scheme(to_stage)
      }
    end

    HEARTBEAT_SPAN_STATUS[event.open? ? :open : :done]
  end

  # The stage a span's task CHANGED TO during the span's window, or nil. A span
  # badges as a stage change when a kind:"transition" TaskEvent for the span's
  # task_slug lands inside [opened_at, closed_at] (an OPEN span's window runs to
  # now); the LAST such transition wins. `stage_transitions` is the pre-grouped
  # bulk map { task_slug => [chronological transitions] } — a blank slug / no
  # transitions returns nil, so this never triggers a per-row query.
  def heartbeat_span_stage_change(event, stage_transitions = {})
    slug = event.task_slug.presence
    return nil if slug.blank? || event.opened_at.blank?

    transitions = (stage_transitions || {})[slug]
    return nil if transitions.blank?

    window_end = event.closed_at || Time.current
    transitions.select { |te| te.occurred_at >= event.opened_at && te.occurred_at <= window_end }
               .last&.to_stage
  end

  # Render a span's status badge from its status meta. A stage-change span renders
  # the shared board badge pill (components/badge — exact /tasks + /deployments
  # look, both themes) wrapped in the stable event-status test hook; every other
  # span keeps the lightweight open/done outcome chip. One code path for the table
  # AND the drawer so they never drift.
  def heartbeat_span_status_badge(status)
    if status[:stage].present?
      tag.span(render("components/badge", text: status[:label], scheme: status[:scheme]),
               class: "hb-outcome-badge", data: { test: "event-status", stage: status[:stage] })
    else
      tag.span(status[:label], class: "hb-outcome", data: { test: "event-status" },
               style: "color: #{status[:color]}")
    end
  end

  # Short, dense timestamp for the "Opened" cell ("Jun 30, 14:07"); the full
  # timestamp rides along in the cell's title. Blank-safe so a span missing an
  # opened_at still renders a dash rather than raising.
  def heartbeat_time(time)
    return "—" if time.blank?

    time.strftime("%b %-d, %H:%M")
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
  # place of the emoji). The acting SOUL (AtomicEvent#agent) rides ON TOP — bold, in
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
  def heartbeat_agent_cell(mascot_slug: nil, pokemon: nil, agent_slug: nil, agent: nil, submascot: false, mascot_test: nil)
    mascot_slug = mascot_slug.presence
    agent_slug  = agent_slug.presence
    mascot_name = pokemon&.name.presence || mascot_slug&.titleize
    soul = (agent || Agent.new(slug: agent_slug, name: agent_slug.titleize)) if agent_slug

    # Avatar faces — the acting SOUL rides ON TOP of the base mascot in a tight
    # overlapping vertical cluster (the soul keeps its own per-soul ring tint).
    soul_face =
      if agent_slug
        tag.span(render(partial: "components/agent_avatar", locals: { agent: soul, size: "xxs" }),
                 class: "hb-ava hb-soulava", style: "color: #{soul.status_color}",
                 title: soul.name, data: { test: "agent-soul", soul: agent_slug })
      end
    mascot_face =
      if mascot_slug
        face = StageAgentsHelper::MascotAgent.new(name: mascot_name, avatar: pokemon&.sprite_url, color: nil)
        tag.span(render(partial: "components/agent_avatar", locals: { agent: face, size: "xxs" }),
                 class: class_names("hb-ava", "hb-mascotava", "hb-submascot" => submascot || agent_slug.present?),
                 title: mascot_name, data: mascot_test ? { test: mascot_test } : {})
      end

    return tag.span("—", class: "hb-meta") unless soul_face || mascot_face

    avatars = tag.div(safe_join([soul_face, mascot_face].compact), class: "hb-avatars")

    # Name column — PRIMARY (the acting soul, else the solo mascot) is bold in one
    # shared primary color; the subordinate mascot name stacks directly BENEATH it in
    # the lighter/less-bold SUB color (not aligned to its avatar, per design).
    names = [tag.span(agent_slug ? soul.name : mascot_name, class: "hb-nameprimary")]
    names << tag.span(mascot_name, class: "hb-namesub") if agent_slug && mascot_slug
    name_col = tag.div(safe_join(names), class: "hb-names")

    tag.div(safe_join([avatars, name_col]),
            class: class_names("hb-agentstack", "hb-solo" => agent_slug.nil?),
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

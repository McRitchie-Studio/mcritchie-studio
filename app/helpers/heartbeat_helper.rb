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
    ti = action.tokens_in.to_i
    to = action.tokens_out.to_i
    return "—" if ti.zero? && to.zero?

    "#{heartbeat_tokens_compact(ti)}/#{heartbeat_tokens_compact(to)}"
  end

  # Cost formatter mirroring the prototype: zero -> "—", sub-cent -> "$0.00",
  # sub-dollar -> 4dp (so fractions of a cent still read), else 2dp.
  def heartbeat_cost(cost)
    cents = cost.to_f
    return "—" if cents <= 0
    return "$0.00" if cents < 0.001

    cents < 1 ? format("$%.4f", cents) : format("$%.2f", cents)
  end
end

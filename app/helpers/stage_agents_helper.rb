# Per-completed-stage agent attribution for the Deploy half of a task's life.
# Reads a task's TaskEvents + its reviewers metadata and answers "who handled
# each finished stage, and how long did that stage take" — the data behind the
# components/stage_agent_avatars partial on the board card and task detail.
module StageAgentsHelper
  # One avatar to render: the soul (or an unresolved-actor stand-in), which
  # finished stage, the time spent in the stage it left, and (reviewers only)
  # the heavy/light review weight. Quacks like an Agent (avatar/avatar_color/
  # avatar_initials/name) so it drops straight into the components/agent_avatar
  # primitive, falling back to the shared AVATAR_COLORS palette when no Agent
  # resolves.
  StageAgent = Struct.new(:stage, :from_label, :label, :weight, :agent, :seconds, keyword_init: true) do
    def avatar
      agent&.avatar
    end

    def avatar_initials
      agent ? agent.avatar_initials : Agent.initials_for(label)
    end

    def avatar_color
      agent ? agent.avatar_color : Agent.avatar_color_for(label)
    end

    def name
      agent&.name.presence || label
    end

    def heavy?
      weight.to_s.casecmp?("heavy")
    end
  end

  # Resolve a TaskEvent#actor — which may be an agent slug, a session id, or an
  # email — to an Agent, or nil when it matches no soul (a raw session id, an
  # external email). agents_by_slug is a prebuilt slug→Agent map so this never
  # queries per call. Email actors match on the local part (alex@… → alex).
  def resolve_actor_agent(actor, agents_by_slug)
    return nil if actor.blank?

    key = actor.to_s.strip.downcase
    agents_by_slug[key] || agents_by_slug[key.split("@").first]
  end

  # The per-completed-stage avatars for a task's Deploy half, in pipeline order:
  #   reviewed  → the two senior reviewers (task.reviewers, with heavy/light)
  #   assembled → the actor of the →assembled event (Steffon, Platform Engineer)
  #   shipped   → the actor of the →shipped event (Avi)
  # Each entry carries seconds_in_from of the event that COMPLETED its stage, so
  # the badge reads "how long that stage took". Returns [] for Build-lane tasks
  # (no review/assembled/shipped events) and old-flow tasks without reviewers —
  # so an Assembled task shows up to 3 (2 seniors + Steffon) and a Shipped task
  # up to 4 (+ Avi).
  def stage_agent_groups(task, agents, events: nil)
    events = Array(events || task.task_events).select(&:to_stage)
                                              .sort_by { |e| [e.occurred_at, e.id.to_i] }
    by_slug = agents.index_by(&:slug)
    entries = []

    if (reviewed = events.reverse.find { |e| e.to_stage == "reviewed" })
      task.reviewers.each do |reviewer|
        entries << StageAgent.new(
          stage: "reviewed",
          from_label: reviewed.from_label,
          label: reviewer["slug"],
          weight: reviewer["weight"],
          agent: resolve_actor_agent(reviewer["slug"], by_slug),
          seconds: reviewed.seconds_in_from
        )
      end
    end

    %w[assembled shipped].each do |stage|
      evt = events.reverse.find { |e| e.to_stage == stage }
      next if evt.nil? || evt.actor.blank?

      entries << StageAgent.new(
        stage: stage,
        from_label: evt.from_label,
        label: evt.actor,
        weight: nil,
        agent: resolve_actor_agent(evt.actor, by_slug),
        seconds: evt.seconds_in_from
      )
    end

    entries
  end
end

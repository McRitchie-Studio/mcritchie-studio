# Per-completed-stage agent attribution across a task's WHOLE life — Build lane
# (designed/building/submitted) AND Deploy lane (reviewed/assembled/shipped).
# Reads a task's TaskEvents + (review only) its reviewers metadata and answers
# "who handled each stage the task passed through, and how long did that stage
# take" — the data behind the components/stage_agent_avatars partial on the board
# card and task detail.
module StageAgentsHelper
  # Pipeline order the avatars render in. Build stages first (the feature agent's
  # half), then Deploy (DevOps's half); `submitted` is the shared seam and counts
  # as a Build stage (the feature agent moved it there). `blocked`/`archived` are
  # side/terminal states with no per-stage crew, so they're excluded.
  STAGE_AGENT_ORDER = %w[designed building submitted reviewed assembled shipped].freeze
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

  # A task's Pokémon mascot rendered as a build-lane "agent" — the mascot IS the
  # feature agent's face. Quacks like an Agent (avatar/avatar_initials/avatar_color/
  # name) so it drops straight into components/agent_avatar.
  MascotAgent = Struct.new(:name, :avatar, keyword_init: true) do
    def avatar_initials
      name.to_s[0, 1].upcase
    end

    def avatar_color
      Agent.avatar_color_for(name)
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

  # Which crew "bunch" a stage belongs to, for the board-card grouping: the Build
  # lane, the review pair, and the Deploy tail render as spaced clusters.
  def stage_lane(stage)
    return :build if Task::BUILD_STAGES.include?(stage)
    return :review if stage == "reviewed"

    stage.to_sym # :assembled, :shipped — each its own compartment
  end

  # Board-card crew: FOUR fixed compartments (Build · Review · Assembled · Shipped)
  # so a full crew fits a small card and nothing reflows on hover. Each cluster
  # stacks its avatars (priority LAST, so it paints on top) and carries the single
  # duration that matters for that compartment:
  #   build     → total build time, shown once submitted; LIVE counter while building
  #   review    → the longer of the two reviews (they share the →reviewed event)
  #   assembled → Steffon's QA-stage time, on its own
  #   shipped   → Avi's ship time, on its own
  CrewCluster = Struct.new(:lane, :stacked, :seconds, :live_since, keyword_init: true)

  def crew_clusters(task, entries)
    by_lane = entries.group_by { |e| stage_lane(e.stage) }

    [].tap do |clusters|
      if (build = by_lane[:build])
        building = %w[designed building].include?(task.stage)
        done = build.any? { |e| e.stage == "submitted" }
        clusters << CrewCluster.new(
          lane: :build,
          stacked: build, # designed→building→submitted; the mascot, last on top
          seconds: (build.sum { |e| e.seconds.to_i } if done),
          live_since: (task.started_at || task.created_at if building)
        )
      end

      if (review = by_lane[:review])
        clusters << CrewCluster.new(
          lane: :review,
          stacked: review.sort_by { |e| e.heavy? ? 1 : 0 }, # heavy last = on top
          seconds: review.map { |e| e.seconds.to_i }.max,
          live_since: nil
        )
      end

      if (assembled = by_lane[:assembled])
        clusters << CrewCluster.new(lane: :assembled, stacked: assembled,
                                    seconds: assembled.sum { |e| e.seconds.to_i }, live_since: nil)
      end

      if (shipped = by_lane[:shipped])
        clusters << CrewCluster.new(lane: :shipped, stacked: shipped,
                                    seconds: shipped.sum { |e| e.seconds.to_i }, live_since: nil)
      end
    end
  end

  # The per-stage avatars for a task's WHOLE journey, in pipeline order
  # (STAGE_AGENT_ORDER). Per stage the task has a landing TaskEvent for:
  #   designed/building/submitted → the actor of that event (the feature agent who
  #               did the build-lane move — designer, builder, submitter)
  #   reviewed  → the two senior reviewers (off the →reviewed event's metadata,
  #               with heavy/light) — the canonical write target, NOT task.reviewers
  #   assembled → the actor of the →assembled event (Steffon, Platform Engineer)
  #   shipped   → the actor of the →shipped event (Avi)
  # When a stage has several landing events (e.g. blocked→building bounces) the
  # MOST RECENT one wins. Each entry carries seconds_in_from of that event, so the
  # pill reads "how long the prior stage took". A build/assembled/shipped event
  # with a blank actor (model-method or conductor move) contributes nothing, and a
  # →reviewed event without reviewers metadata contributes nothing — so a task with
  # no stage events at all (or only crewless ones) renders []. A Build-lane card
  # thus shows its designer/builder/submitter, and a Shipped card shows up to
  # designer/builder/submitter + 2 seniors + Steffon + Avi.
  def stage_agent_groups(task, agents, events: nil, mascot: nil)
    events = Array(events || task.task_events).select(&:to_stage)
                                              .sort_by { |e| [e.occurred_at, e.id.to_i] }
    by_slug = agents.index_by(&:slug)
    mascot_agent = mascot && MascotAgent.new(name: mascot.name, avatar: mascot.sprite_url)

    STAGE_AGENT_ORDER.flat_map do |stage|
      evt = events.reverse.find { |e| e.to_stage == stage }
      next [] if evt.nil?

      if stage == "reviewed"
        # The pair is written to the →reviewed EVENT's metadata (Task#stage_event_metadata),
        # not Task.metadata — read it off the event so the avatars actually populate.
        Task.normalize_reviewers(evt.metadata["reviewers"]).map do |reviewer|
          StageAgent.new(
            stage: stage,
            from_label: evt.from_label,
            label: reviewer["slug"],
            weight: reviewer["weight"],
            agent: resolve_actor_agent(reviewer["slug"], by_slug),
            seconds: evt.seconds_in_from
          )
        end
      elsif evt.actor.present?
        [StageAgent.new(
          stage: stage,
          from_label: evt.from_label,
          label: evt.actor,
          weight: nil,
          # Build-lane stages wear the task's mascot (the feature agent's face);
          # deploy-lane stages keep their real actor.
          agent: (mascot_agent if Task::BUILD_STAGES.include?(stage)) || resolve_actor_agent(evt.actor, by_slug),
          seconds: evt.seconds_in_from
        )]
      else
        []
      end
    end
  end
end

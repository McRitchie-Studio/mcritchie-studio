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
  # The canonical role owner of each Deploy-lane stage — who handles it by role
  # when the mover left no actor (a conductor/model transition records only the
  # spine). Steffon (Platform Engineer) QAs the assembled RC; Avi runs the ship
  # e2e. Used to backfill a BLANK actor so the Deploy crew never goes faceless — a
  # PRESENT but unresolved actor (a raw session id) is left as-is, not overridden.
  STAGE_OWNER = { "assembled" => "steffon", "shipped" => "avi" }.freeze
  # The stage each pipeline stage produces next, and the task timestamp marking
  # when the task entered a stage — together they place the LIVE "who's on it now"
  # ticker on the consolidated timeline + board.
  NEXT_PIPELINE_STAGE = { "designed" => "building", "building" => "submitted",
                          "submitted" => "reviewed", "reviewed" => "assembled",
                          "assembled" => "shipped" }.freeze
  STAGE_ENTERED_AT = { "designed" => :created_at, "building" => :started_at,
                       "submitted" => :submitted_at, "reviewed" => :reviewed_at,
                       "assembled" => :assembled_at }.freeze
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

  BUILD_STEP_NEXT = { "designed" => "building", "building" => "submitted", "submitted" => "reviewed" }.freeze
  BUILD_STEP_START = { "designed" => :created_at, "building" => :started_at, "submitted" => :submitted_at }.freeze

  # Board-aware crew columns. The upstream build stages (designed · building) always
  # split into the design + building agents, on either board; the Build board (/tasks)
  # keeps that split through submitted. Everything else is Deploy-style: the build
  # collapses into one circle and the pipeline shows build · review · assembled. Only
  # a shipped task earns the fourth (shipped) lane; blocked mirrors Assembled's three
  # (a block lands from reviewed or assembled). Returns an ordered array of CrewCluster;
  # the partial renders one fixed grid column per entry (an empty entry reserves its slot).
  def crew_columns(task, entries, board:, mascot: nil, agents: nil, events: nil)
    if %w[designed building].include?(task.stage) || (board == :build && task.stage != "blocked")
      return build_step_columns(task, entries, mascot)
    end

    by_lane = crew_clusters(task, entries).index_by(&:lane)

    # Surface LIVE deploy-stage work (review picked · Steffon QA · Avi ship) as a
    # ticking cluster in its lane before the transition lands — the Deploy mirror of
    # the build lane's live counter. Needs the agent map to resolve the intent's
    # actor; when it isn't passed (older callers) this is simply skipped, so no-
    # intent boards render exactly as before.
    if agents
      by_slug = agents.index_by(&:slug)
      mascot_agent = mascot && MascotAgent.new(name: mascot.name, avatar: mascot.sprite_url)
      intents = Array(events || task.task_events).select(&:intent?)
      work = in_progress_work(task, by_slug, mascot_agent, intents)
      if work && %i[review assembled shipped].include?(work[:lane]) && by_lane[work[:lane]].nil?
        by_lane[work[:lane]] = CrewCluster.new(lane: work[:lane], stacked: work[:agents],
                                               seconds: nil, live_since: work[:live_since])
      end
    end

    lanes = %i[build review assembled]
    lanes << :shipped if task.stage == "shipped"
    lanes.map { |lane| by_lane[lane] || CrewCluster.new(lane: lane, stacked: [], seconds: nil, live_since: nil) }
  end

  # /tasks build board: the three build steps split out, each wearing the task's
  # mascot + the time spent IN that step (live for the current step). Unreached
  # steps render an empty, reserved column.
  def build_step_columns(task, entries, mascot)
    face = mascot && MascotAgent.new(name: mascot.name, avatar: mascot.sprite_url)
    by_to_stage = entries.index_by(&:stage)
    reached_idx = Task::STAGES.index(task.stage).to_i

    %w[designed building submitted].map do |stage|
      reached = reached_idx >= Task::STAGES.index(stage)
      current = task.stage == stage
      agent = face || by_to_stage[stage]&.agent # the mascot, else this step's own actor
      CrewCluster.new(
        lane: stage.to_sym,
        stacked: (reached && agent ? [StageAgent.new(stage: stage, agent: agent)] : []),
        seconds: (by_to_stage[BUILD_STEP_NEXT[stage]]&.seconds.to_i if reached && !current),
        live_since: ((task.public_send(BUILD_STEP_START[stage]) || task.created_at) if reached && current)
      )
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
    events = Array(events || task.task_events).select { |e| e.transition? && e.to_stage }
                                              .sort_by { |e| [e.occurred_at, e.id.to_i] }
    by_slug = agents.index_by(&:slug)
    mascot_agent = mascot && MascotAgent.new(name: mascot.name, avatar: mascot.sprite_url)

    STAGE_AGENT_ORDER.flat_map do |stage|
      evt = events.reverse.find { |e| e.to_stage == stage }
      evt ? event_stage_agents(evt, by_slug, mascot_agent) : []
    end
  end

  # The avatar(s) for ONE completed (transition) event: the senior pair off a
  # →reviewed event's metadata (the canonical write target, NOT Task.metadata),
  # else the single mover. Build-lane stages wear the task's mascot (the feature
  # agent's face); the Deploy tail keeps its real actor. An actor-LESS
  # assembled/shipped move (a conductor/model transition that recorded only the
  # spine) is attributed to the stage's canonical role owner (Steffon QAs
  # `assembled`, Avi ships) so the Deploy crew never goes blank — but a PRESENT yet
  # unresolved actor (a raw session id) keeps its palette stand-in, not overridden.
  def event_stage_agents(evt, by_slug, mascot_agent)
    stage = evt.to_stage
    if stage == "reviewed"
      Task.normalize_reviewers(evt.metadata["reviewers"]).map do |reviewer|
        StageAgent.new(stage: stage, from_label: evt.from_label, label: reviewer["slug"],
                       weight: reviewer["weight"], agent: resolve_actor_agent(reviewer["slug"], by_slug),
                       seconds: evt.seconds_in_from)
      end
    elsif evt.actor.present?
      [StageAgent.new(stage: stage, from_label: evt.from_label, label: evt.actor, weight: nil,
                      agent: (mascot_agent if Task::BUILD_STAGES.include?(stage)) || resolve_actor_agent(evt.actor, by_slug),
                      seconds: evt.seconds_in_from)]
    elsif (owner = (STAGE_OWNER[stage] && by_slug[STAGE_OWNER[stage]]))
      [StageAgent.new(stage: stage, from_label: evt.from_label, label: owner.slug, weight: nil,
                      agent: owner, seconds: evt.seconds_in_from)]
    else
      []
    end
  end

  # The CONSOLIDATED timeline for /tasks/:id — one ordered list that replaces the
  # separate "Stage Crew" + "Stage Timeline" panels. Every completed TRANSITION is
  # a block (from→to, the agent(s) that COMPLETED it, time-in-stage, and the
  # model/tokens/cost the agent reported), and when the task is still live a
  # trailing IN-PROGRESS block shows who is on the current stage right now with a
  # green live ticker (the build lane from the mascot + entry time; the deploy lane
  # from the OPEN intent). Returns an array of TimelineBlock in pipeline order.
  TimelineBlock = Struct.new(:event, :from_label, :to_label, :from_stage, :to_stage,
                             :occurred_at, :seconds, :agents, :model, :tokens, :cost,
                             :source, :live_since, :in_progress, :backfilled, keyword_init: true) do
    def in_progress? = in_progress
    def usage? = model.present? || tokens.present? || cost.present?
  end

  def stage_timeline(task, agents, events: nil, mascot: nil)
    events = Array(events || task.task_events)
    by_slug = agents.index_by(&:slug)
    mascot ||= Pokemon.find_by(slug: task.devops["mascot"].to_s.presence)
    mascot_agent = mascot && MascotAgent.new(name: mascot.name, avatar: mascot.sprite_url)

    transitions = events.select { |e| e.transition? && e.to_stage }.sort_by { |e| [e.occurred_at, e.id.to_i] }
    intents = events.select(&:intent?)

    blocks = transitions.map do |evt|
      # Build-lane blocks always wear the mascot (the feature agent's face), even on
      # a model-method create that left no actor — that's the "agent the moment a
      # task is designed". The deploy tail uses the real per-event attribution.
      agents_for = if Task::BUILD_STAGES.include?(evt.to_stage) && mascot_agent
        [StageAgent.new(stage: evt.to_stage, from_label: evt.from_label, agent: mascot_agent, seconds: evt.seconds_in_from)]
      else
        event_stage_agents(evt, by_slug, mascot_agent)
      end
      TimelineBlock.new(event: evt, from_label: evt.from_label, to_label: evt.to_label,
                        from_stage: evt.from_stage, to_stage: evt.to_stage, occurred_at: evt.occurred_at,
                        seconds: evt.seconds_in_from, agents: agents_for, model: evt.model,
                        tokens: evt.tokens_total, cost: evt.cost, source: evt.source,
                        live_since: nil, in_progress: false, backfilled: evt.backfilled?)
    end

    if (work = in_progress_work(task, by_slug, mascot_agent, intents))
      blocks << TimelineBlock.new(
        event: nil, from_label: Task::STAGE_LABELS.fetch(task.stage, task.stage.to_s.humanize),
        to_label: Task::STAGE_LABELS.fetch(work[:to_stage], work[:to_stage].to_s.humanize),
        from_stage: task.stage, to_stage: work[:to_stage], occurred_at: work[:live_since],
        seconds: nil, agents: work[:agents], model: nil, tokens: nil, cost: nil, source: nil,
        live_since: work[:live_since], in_progress: true, backfilled: false
      )
    end

    blocks
  end

  # The work in progress on `task` right now — who's on it + when they started — or
  # nil when the task is idle (shipped/blocked/archived, or awaiting a not-yet-
  # recorded intent). Build stages derive from the mascot + the stage's entry time;
  # deploy stages read the OPEN intent (review pair / Steffon QA / Avi ship). Shape:
  # { to_stage:, lane:, agents: [StageAgent], live_since: Time }.
  def in_progress_work(task, by_slug, mascot_agent, intents)
    stage = task.stage
    return nil unless NEXT_PIPELINE_STAGE.key?(stage)

    # Only designed/building are "still building" (mascot + entry time). Once
    # submitted the build is done and the in-progress work is the DEPLOY lane —
    # the review pair, then Steffon's QA, then Avi's ship — read off the open intent.
    if %w[designed building].include?(stage)
      return nil unless mascot_agent

      since = (STAGE_ENTERED_AT[stage] && task.public_send(STAGE_ENTERED_AT[stage])) || task.created_at
      { to_stage: stage, lane: :build, live_since: since,
        agents: [StageAgent.new(stage: stage, agent: mascot_agent)] }
    else
      target = NEXT_PIPELINE_STAGE[stage]
      intent = intents.select { |e| e.to_stage == target }.max_by { |e| [e.occurred_at, e.id.to_i] }
      return nil if intent.nil?

      agents = intent_stage_agents(intent, by_slug, target)
      return nil if agents.empty?

      { to_stage: target, lane: stage_lane(target), live_since: intent.occurred_at, agents: agents }
    end
  end

  # The avatar(s) for an OPEN intent: the senior pair (→reviewed) or the single
  # owner (Steffon→assembled, Avi→shipped), canonical-owner backfilled like a
  # completed event so a bare intent still shows a face.
  def intent_stage_agents(intent, by_slug, target = intent.to_stage)
    if target == "reviewed"
      Task.normalize_reviewers(intent.metadata["reviewers"]).map do |reviewer|
        StageAgent.new(stage: target, label: reviewer["slug"], weight: reviewer["weight"],
                       agent: resolve_actor_agent(reviewer["slug"], by_slug))
      end
    else
      owner = resolve_actor_agent(intent.actor, by_slug) || (STAGE_OWNER[target] && by_slug[STAGE_OWNER[target]])
      owner ? [StageAgent.new(stage: target, label: intent.actor.presence || owner.slug, agent: owner)] : []
    end
  end
end

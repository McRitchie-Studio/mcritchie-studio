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
  # the primary/light review role. Quacks like an Agent (avatar/avatar_color/
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

    # The deep-review seat. Recognizes the legacy "heavy" weight as "primary" too,
    # so review intents recorded BEFORE the rename (TaskEvent.metadata still says
    # "heavy") render identically to new "primary" ones — no data migration of the
    # append-only event metadata.
    def primary?
      %w[primary heavy].include?(weight.to_s.strip.downcase)
    end

    # The canonical role label for display — normalizes a legacy "heavy" record to
    # the current "primary" role so old and new records both read "Primary" in the
    # UI. nil when this agent carries no review role (a build/deploy-lane mover).
    def role_label
      return nil if weight.blank?

      primary? ? ReviewerSelector.primary_role : weight.to_s.strip.downcase
    end
  end

  # A task's Pokémon mascot rendered as a build-lane "agent" — the mascot IS the
  # feature agent's face. Quacks like an Agent (avatar/avatar_initials/avatar_color/
  # name) so it drops straight into components/agent_avatar. `color` is the
  # mascot's signature type color (its least-common type, via Pokemon#signature_color);
  # it backs the avatar circle so e.g. Dragonite wears Dragon, falling back to the
  # name-derived palette color when no type is seeded.
  MascotAgent = Struct.new(:name, :avatar, :color, keyword_init: true) do
    def avatar_initials
      name.to_s[0, 1].upcase
    end

    def avatar_color
      color.presence || Agent.avatar_color_for(name)
    end
  end

  # The mascot face for one event — its baked snapshot when present (every staged
  # transition bakes one now, so a gate-evolved form stays on the card it owned),
  # else the caller's fallback (the task's live mascot, for pre-snapshot rows).
  def event_mascot_agent(evt, fallback)
    snapshot = evt.mascot_snapshot
    name = snapshot["name"].presence || snapshot["slug"].presence
    return fallback if name.blank?

    MascotAgent.new(
      name: name,
      avatar: snapshot["avatar"].presence,
      color: snapshot["color"].presence
    )
  end

  # The task's CURRENT mascot as a board face — the single construction point for
  # a MascotAgent built off a live task + its Pokémon. A shiny draw
  # (devops.mascot_shiny) wears the shiny sprite; event snapshots don't come
  # through here (their avatar URL is baked shiny-aware at record time).
  def task_mascot_face(task, mascot)
    return nil unless mascot

    MascotAgent.new(name: mascot.name,
                    avatar: mascot.display_sprite(shiny: task.mascot_shiny?),
                    color: mascot.signature_color)
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
        # Live only while actively `building` (a real claim) — a `designed`/unclaimed
        # task is not being built, so it carries no green ticker.
        building = task.stage == "building"
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
          stacked: review.sort_by { |e| e.primary? ? 1 : 0 }, # primary last = on top
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
  # collapses into one circle and the pipeline shows build · review · assembled. The
  # assembled AND shipped columns both carry the fourth (deploy/ship) lane — assembled
  # reserves it (and fills it from an open ship intent) so the card doesn't reflow when
  # it ships; blocked mirrors the earlier three (a block lands from reviewed or
  # assembled). Returns an ordered array of CrewCluster;
  # the partial renders one fixed grid column per entry (an empty entry reserves its slot).
  # True when this board renders the split build steps (each wearing the mascot)
  # rather than the collapsed Deploy clusters: always for designed/building, and
  # through submitted on the Build board (/tasks). The mascot is painted from
  # `devops.mascot` here independent of any crew entries — so a card on such a
  # board shows its mascot even before the first actored stage event lands.
  def build_step_board?(task, board)
    %w[designed building].include?(task.stage) || (board == :build && task.stage != "blocked")
  end

  # Whether the stage-crew partial should render at all. The board card (stack)
  # shows the build-lane mascot the moment a task is created — a fresh `designed`
  # task has only a blank-actor genesis event, so `stage_agent_groups` is empty,
  # but its mascot is the feature agent's face and `build_step_columns` paints it
  # without entries. The detail (:detailed) panel still needs real crew entries.
  def stage_crew_renderable?(task, entries, mascot:, variant:, board:)
    return entries.any? if variant.to_sym == :detailed

    entries.any? || (mascot.present? && (build_step_board?(task, board) || task.blocked?))
  end

  def crew_columns(task, entries, board:, mascot: nil, agents: nil, events: nil)
    return build_step_columns(task, entries, mascot) if build_step_board?(task, board)

    by_lane = crew_clusters(task, entries).index_by(&:lane)
    by_lane[:build] ||= blocked_build_crew(task, mascot) if task.blocked?

    # Surface LIVE deploy-stage work (review picked · Steffon QA · Avi ship) as a
    # ticking cluster in its lane before the transition lands — the Deploy mirror of
    # the build lane's live counter. Needs the agent map to resolve the intent's
    # actor; when it isn't passed (older callers) this is simply skipped, so no-
    # intent boards render exactly as before.
    if agents
      by_slug = agents.index_by(&:slug)
      mascot_agent = task_mascot_face(task, mascot)
      intents = Array(events || task.task_events).select(&:intent?)
      work = in_progress_work(task, by_slug, mascot_agent, intents)
      if work && %i[review assembled shipped].include?(work[:lane])
        existing = by_lane[work[:lane]]
        by_lane[work[:lane]] =
          if existing.nil?
            CrewCluster.new(lane: work[:lane], stacked: work[:agents], seconds: nil, live_since: work[:live_since])
          elsif work[:lane] == :review && existing.live_since.nil?
            # Rework can send a task back to `submitted` after an earlier review
            # completed. The old review cluster is historical; while a fresh review
            # intent is open, the review lane must show the current pair ticking live.
            CrewCluster.new(lane: :review, stacked: work[:agents], seconds: existing.seconds,
                            live_since: work[:live_since])
          elsif work[:lane] == :assembled && existing.live_since.nil?
            # Standard-flow QA: the member is already `assembled` (the merge flipped
            # it), so the assembled column is ALREADY filled (Steffon, static, with
            # the merge-wait duration). Mark it LIVE in place — Steffon is QA-ing the
            # RC right now (the prepare window) — keeping its avatars + static time
            # instead of discarding them. (Without this, the pre-filled assembled slot
            # would swallow the live QA ticker and Steffon would never tick on the
            # board in the standard flow — the reviewer's blocker.)
            CrewCluster.new(lane: :assembled, stacked: existing.stacked,
                            seconds: existing.seconds, live_since: work[:live_since])
          else
            existing
          end
      end
    end

    apply_third_evolution!(by_lane, third_evolution(task, events: events))

    lanes = %i[build review assembled]
    # The deploy/ship lane is reserved on the assembled column too — not just once
    # shipped. An assembled card holds the empty fourth slot so it never reflows when
    # the ship lands, and the open ship intent (Avi deploying) surfaced by
    # in_progress_work above fills that slot with a LIVE ticker. Blocked keeps the
    # earlier three (a block lands from reviewed or assembled).
    lanes << :shipped if %w[assembled shipped].include?(task.stage)
    lanes.map { |lane| by_lane[lane] || CrewCluster.new(lane: lane, stacked: [], seconds: nil, live_since: nil) }
  end

  # Board mirror of the timeline's Evolve card: when a task reached a THIRD form at
  # the assembled gate, stack that evolved form onto the FIRST (build) crew — the
  # mascot's whole lineage lives together on the card it was born on — and drop the
  # now-redundant companion from the deploy (assembled/shipped) clusters so the
  # evolved face shows once (on the first crew), not again beside Steffon/Avi. A
  # no-op unless a third evolution fired, and left untouched when there is no build
  # crew to home the form (so the deploy companion still carries it). Mutates the
  # by-lane cluster map in place.
  def apply_third_evolution!(by_lane, evo)
    return unless evo

    build = by_lane[:build]
    return unless build

    build.stacked += [StageAgent.new(stage: "assembled", agent: evo.to_face)]
    %i[assembled shipped].each do |lane|
      cluster = by_lane[lane]
      cluster.stacked = cluster.stacked.reject { |a| a.agent.is_a?(MascotAgent) } if cluster
    end
  end

  def blocked_build_crew(task, mascot)
    face = task_mascot_face(task, mascot)
    return nil unless face

    CrewCluster.new(
      lane: :build,
      stacked: [StageAgent.new(stage: "building", agent: face)],
      seconds: nil,
      live_since: nil
    )
  end

  # /tasks build board: the three build steps split out, each wearing the task's
  # mascot + the time spent IN that step. Only the `building` step ticks a LIVE
  # counter (a real, active claim); a `designed`/unclaimed step shows the mascot
  # with no ticker. Unreached steps render an empty, reserved column.
  def build_step_columns(task, entries, mascot)
    face = task_mascot_face(task, mascot)
    by_to_stage = entries.index_by(&:stage)
    reached_idx = Task::STAGES.index(task.stage).to_i

    %w[designed building submitted].map do |stage|
      reached = reached_idx >= Task::STAGES.index(stage)
      current = task.stage == stage
      # The green LIVE ticker means "an agent is actively building this right now",
      # so it fires ONLY while the task is `building` — a real claim (move →
      # building). A `designed` task is filed but UNCLAIMED (nobody has picked it
      # up — e.g. a conductor's bin/release follow-up), and a `submitted` task has
      # handed off to the deploy lane; neither is being built, so each shows just
      # the mascot face (its identity) with no live counter — no false intent.
      building_now = current && stage == "building"
      agent = by_to_stage[stage]&.agent || face # historical event mascot, else current task mascot
      CrewCluster.new(
        lane: stage.to_sym,
        stacked: (reached && agent ? [StageAgent.new(stage: stage, agent: agent)] : []),
        seconds: (by_to_stage[BUILD_STEP_NEXT[stage]]&.seconds.to_i if reached && !current),
        live_since: ((task.public_send(BUILD_STEP_START[stage]) || task.created_at) if building_now)
      )
    end
  end

  # The per-stage avatars for a task's WHOLE journey, in pipeline order
  # (STAGE_AGENT_ORDER). Per stage the task has a landing TaskEvent for:
  #   designed/building/submitted → the actor of that event (the feature agent who
  #               did the build-lane move — designer, builder, submitter)
  #   reviewed  → the two senior reviewers (off the →reviewed event's metadata,
  #               with primary/light) — the canonical write target, NOT task.reviewers
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
    mascot_agent = task_mascot_face(task, mascot)

    STAGE_AGENT_ORDER.flat_map do |stage|
      evt = events.reverse.find { |e| e.to_stage == stage }
      evt ? event_stage_agents(evt, by_slug, mascot_agent) : []
    end
  end

  # The avatar(s) for ONE completed (transition) event: the senior pair off a
  # →reviewed event's metadata (the canonical write target, NOT Task.metadata),
  # else the single mover. Build-lane stages wear the task's mascot (the feature
  # agent's face) from the event snapshot when present, falling back to the current
  # task mascot for legacy rows; the Deploy tail keeps its real actor. An
  # actor-LESS assembled/shipped move (a conductor/model transition that recorded
  # only the spine) is attributed to the stage's canonical role owner (Steffon QAs
  # `assembled`, Avi ships) so the Deploy crew never goes blank — but a PRESENT yet
  # unresolved actor (a raw session id) keeps its palette stand-in, not overridden.
  def event_stage_agents(evt, by_slug, mascot_agent)
    stage = evt.to_stage
    if Task::BUILD_STAGES.include?(stage)
      if (agent = event_mascot_agent(evt, mascot_agent))
        [StageAgent.new(stage: stage, from_label: evt.from_label,
                        label: evt.actor.presence || evt.mascot_snapshot["slug"].presence || agent.name,
                        weight: nil, agent: agent, seconds: evt.seconds_in_from)]
      elsif evt.actor.present?
        [StageAgent.new(stage: stage, from_label: evt.from_label, label: evt.actor, weight: nil,
                        agent: resolve_actor_agent(evt.actor, by_slug), seconds: evt.seconds_in_from)]
      else
        []
      end
    elsif stage == "reviewed"
      Task.normalize_reviewers(evt.metadata["reviewers"]).map do |reviewer|
        StageAgent.new(stage: stage, from_label: evt.from_label, label: reviewer["slug"],
                       weight: reviewer["weight"], agent: resolve_actor_agent(reviewer["slug"], by_slug),
                       seconds: evt.seconds_in_from)
      end
    elsif evt.actor.present?
      [StageAgent.new(stage: stage, from_label: evt.from_label, label: evt.actor, weight: nil,
                      agent: (mascot_agent if Task::BUILD_STAGES.include?(stage)) || resolve_actor_agent(evt.actor, by_slug),
                      seconds: evt.seconds_in_from)] + [deploy_mascot_companion(evt, mascot_agent)].compact
    elsif (owner = (STAGE_OWNER[stage] && by_slug[STAGE_OWNER[stage]]))
      [StageAgent.new(stage: stage, from_label: evt.from_label, label: owner.slug, weight: nil,
                      agent: owner, seconds: evt.seconds_in_from)] + [deploy_mascot_companion(evt, mascot_agent)].compact
    else
      [deploy_mascot_companion(evt, mascot_agent)].compact
    end
  end

  # The stages whose crew card carries the task's Pokémon ALONGSIDE the deploy
  # soul — how the SECOND evolution gate (assembled) actually shows its face.
  # The mascot rides the card it earned: Steffon assembles next to Charizard,
  # and the ship card keeps him. Reviewed stays the pure senior pair (the
  # two-column review layout is a deliberate 2-up grid).
  MASCOT_COMPANION_STAGES = %w[assembled shipped].freeze

  def deploy_mascot_companion(evt, mascot_agent)
    return nil unless MASCOT_COMPANION_STAGES.include?(evt.to_stage)

    agent = event_mascot_agent(evt, mascot_agent)
    return nil unless agent

    StageAgent.new(stage: evt.to_stage, from_label: evt.from_label,
                   label: evt.mascot_snapshot["slug"].presence || agent.name,
                   weight: nil, agent: agent, seconds: nil)
  end

  # A task's THIRD-stage evolution — the NEW form its Pokémon reaches at Steffon's
  # assembled gate (Mareep submits as Flaaffy, then assembles as Ampharos). Present
  # only when a form actually appeared there, so 1-/2-stage lines and not-yet-
  # assembled tasks return nil. History-stable and presentation-only: it reads the
  # mascot SNAPSHOTS baked on the TaskEvents — the assembled transition's form vs the
  # form that ENTERED the gate (the snapshot on the event that landed the task in the
  # stage the assemble came from) — never the live task or a schema field. The
  # snapshot diff, not devops.mascot_stage, is the source of truth: the stage is
  # stamped at the gate even when nothing evolves (Task#evolve_stage_mascot), so a
  # 2-stage line still reads mascot_stage == 2 with no new form. This is the single
  # source both surfaces consume: the timeline lifts the reveal into its own "Evolve"
  # card (leaving Steffon alone on Reviewed → Assembled), and the board card stacks
  # the evolved form onto the FIRST (build) crew.
  EvolutionReel = Struct.new(:from, :to, :trigger, keyword_init: true)
  ThirdEvolution = Struct.new(:event, :from, :to, keyword_init: true) do
    def from_face = snapshot_face(from)
    def to_face   = snapshot_face(to)

    private

    def snapshot_face(snap)
      MascotAgent.new(name: snap["name"].presence || snap["slug"],
                      avatar: snap["avatar"].presence, color: snap["color"].presence)
    end
  end

  def third_evolution(task, events: nil)
    return nil unless Pokemon.table_exists?

    transitions = Array(events || task.task_events)
                  .select { |e| e.transition? && e.to_stage }
                  .sort_by { |e| [e.occurred_at, e.id.to_i] }
    idx = transitions.rindex { |e| e.to_stage == "assembled" }
    return nil unless idx&.positive?

    evt = transitions[idx]
    # The form that ENTERED the assembled gate: the snapshot on the event that landed
    # the task in the stage the assemble came from (normally →reviewed), falling back
    # to the immediately-preceding transition when that landing event is missing.
    entered = transitions[0...idx].reverse.find { |e| e.to_stage == evt.from_stage } ||
              transitions[idx - 1]
    from_snap = entered.mascot_snapshot
    to_snap = evt.mascot_snapshot
    return nil if from_snap["slug"].blank? || to_snap["slug"].blank?
    return nil if from_snap["slug"] == to_snap["slug"]

    # A genuine THIRD evolution means the mascot ALREADY evolved once at the submit
    # gate before this assemble step — so the form ENTERING the gate is itself an
    # evolution, never a base form. Without this guard a task that reaches assembled
    # WITHOUT passing the submit gate (a skipped or bypassed submit) evolves base →
    # first form AT the gate, and that FIRST evolution (Charmander → Charmeleon) would
    # render as a bogus Evolve card. The lookup is bounded — only the few
    # assembled/shipped cards whose mascot actually changed at the gate reach it.
    entering = Pokemon.find_by(slug: from_snap["slug"])
    return nil if entering.nil? || entering.base_form?

    ThirdEvolution.new(event: evt, from: from_snap, to: to_snap)
  end

  # The CONSOLIDATED timeline for /tasks/:id — one ordered list that replaces the
  # separate "Stage Crew" + "Stage Timeline" panels. Every completed TRANSITION is
  # a block (from→to, the agent(s) that COMPLETED it, time-in-stage, and the
  # model/tokens/cost the agent reported). Deploy-lane live work appends an
  # IN-PROGRESS block from the open intent; the build lane is special because
  # `building` is itself the intent stage, so the existing →Building transition is
  # marked live instead of adding a second "Building" card. Returns an array of
  # TimelineBlock in pipeline order.
  TimelineBlock = Struct.new(:event, :from_label, :to_label, :from_stage, :to_stage,
                             :occurred_at, :seconds, :agents, :model, :tokens, :cost,
                             :source, :live_since, :in_progress, :backfilled, :evolution,
                             keyword_init: true) do
    def in_progress? = in_progress
    def usage? = model.present? || tokens.present? || cost.present?
    # An "Evolve" card — a synthetic reel spliced in after the assembled block for a
    # third-stage evolution; it carries an EvolutionReel instead of a real transition.
    def evolution? = evolution.present?
  end

  def stage_timeline(task, agents, events: nil, mascot: nil)
    events = Array(events || task.task_events)
    by_slug = agents.index_by(&:slug)
    mascot ||= Pokemon.find_by(slug: task.devops["mascot"].to_s.presence)
    mascot_agent = task_mascot_face(task, mascot)

    transitions = events.select { |e| e.transition? && e.to_stage }.sort_by { |e| [e.occurred_at, e.id.to_i] }
    intents = events.select(&:intent?)

    blocks = transitions.map do |evt|
      agents_for = event_stage_agents(evt, by_slug, mascot_agent)
      TimelineBlock.new(event: evt, from_label: evt.from_label, to_label: evt.to_label,
                        from_stage: evt.from_stage, to_stage: evt.to_stage, occurred_at: evt.occurred_at,
                        seconds: evt.seconds_in_from, agents: agents_for, model: evt.model,
                        tokens: evt.tokens_total, cost: evt.cost, source: evt.source,
                        live_since: nil, in_progress: false, backfilled: evt.backfilled?)
    end

    if (work = in_progress_work(task, by_slug, mascot_agent, intents))
      if task.stage == "building" && merge_live_build_work!(blocks, work)
        return blocks
      end

      # The timeline frames live work as the real pipeline TRANSITION it produces —
      # `to_stage` is the next stage and `timeline_agents` is that stage's crew. This
      # is what keeps a re-homed QA intent from rendering "Assembled → Assembled":
      # it reads as the ship it rides toward, "Assembled → Shipped · Avi" (the board
      # still shows Steffon QA-ing the assembled lane off `work[:agents]`).
      # The single badge on a live card shows the ACTIVE (gerund) form of the stage
      # still underway — "Assembling", not "Assembled" — since the work isn't done.
      blocks << TimelineBlock.new(
        event: nil, from_label: Task.active_stage_label(task.stage),
        to_label: Task::STAGE_LABELS.fetch(work[:to_stage], work[:to_stage].to_s.humanize),
        from_stage: task.stage, to_stage: work[:to_stage], occurred_at: work[:live_since],
        seconds: nil, agents: work[:timeline_agents], model: nil, tokens: nil, cost: nil, source: nil,
        live_since: work[:live_since], in_progress: true, backfilled: false
      )
    end

    insert_evolution_card!(blocks, third_evolution(task, events: events))

    blocks
  end

  # Lift the assembled gate's THIRD evolution into its own "Evolve" reel right after
  # Steffon's Reviewed → Assembled card. The reel becomes the SINGLE home of the
  # evolved form, so the mascot companion is stripped off BOTH deploy cards — Steffon's
  # assembled AND Avi's shipped — leaving each soul alone; the Evolve card is credited
  # to whoever triggered the assemble. A no-op unless a third evolution fired. Mutates
  # `blocks` in place.
  def insert_evolution_card!(blocks, evo)
    return unless evo

    idx = blocks.index { |b| b.event&.id == evo.event.id }
    return unless idx

    assembled = blocks[idx]
    trigger = assembled.agents.find { |a| !a.agent.is_a?(MascotAgent) }
    assembled.agents = assembled.agents.reject { |a| a.agent.is_a?(MascotAgent) }
    if (shipped = blocks.find { |b| b.to_stage == "shipped" })
      shipped.agents = shipped.agents.reject { |a| a.agent.is_a?(MascotAgent) }
    end

    blocks.insert(idx + 1, TimelineBlock.new(
                             event: evo.event, from_label: "Evolve", to_label: "Evolve",
                             from_stage: nil, to_stage: nil, occurred_at: evo.event.occurred_at,
                             # Carry the assemble event's timing so the shared metric +
                             # footer sections read a Duration and a Started → Completed
                             # stamp, like every other card. Model / tokens / cost stay
                             # blank — those belong to the Reviewed → Assembled card.
                             seconds: evo.event.seconds_in_from, agents: [], model: nil, tokens: nil, cost: nil,
                             source: nil, live_since: nil, in_progress: false, backfilled: false,
                             evolution: EvolutionReel.new(from: evo.from_face, to: evo.to_face, trigger: trigger)
                           ))
  end

  def merge_live_build_work!(blocks, work)
    block = blocks.reverse.find { |candidate| candidate.to_stage == "building" }
    return false unless block

    block.live_since = work[:live_since]
    block.in_progress = true
    block.agents = work[:timeline_agents] if block.agents.blank?
    true
  end

  # The work in progress on `task` right now — who's on it + when they started — or
  # nil when the task is idle (designed/unclaimed, shipped/blocked/archived, or
  # awaiting a not-yet-recorded intent). The build lane is live only while
  # `building` (mascot + entry time); deploy stages read the OPEN intent (review
  # pair / Steffon QA / Avi ship).
  #
  # The result serves TWO different views, which is why it carries two crews:
  #   * BOARD (crew_columns) reads `lane` + `agents` — the re-homed LANE and the
  #     soul physically working it (Steffon QA-ing the assembled lane).
  #   * TIMELINE (stage_timeline) reads `to_stage` + `timeline_agents` — the real
  #     pipeline TRANSITION this work produces (the next stage) and that stage's
  #     crew. They coincide for every lane EXCEPT the re-homed QA intent, where the
  #     board says "assembled · Steffon" but the timeline says "shipped · Avi".
  # Shape: { to_stage:, lane:, agents: [StageAgent], timeline_agents: [StageAgent], live_since: Time }.
  def in_progress_work(task, by_slug, mascot_agent, intents)
    stage = task.stage
    return nil unless NEXT_PIPELINE_STAGE.key?(stage)
    target = NEXT_PIPELINE_STAGE[stage] # the real next pipeline stage — the timeline badge target

    # Only `building` is "still building" — an active claim (mascot + entry time).
    # A `designed` task is filed but UNCLAIMED, so it is NOT live build work (no
    # green ticker on the timeline). Once submitted the build is done and the
    # in-progress work is the DEPLOY lane — the review pair, then Steffon's QA,
    # then Avi's ship — read off the open intent.
    if stage == "building"
      return nil unless mascot_agent

      since = (STAGE_ENTERED_AT[stage] && task.public_send(STAGE_ENTERED_AT[stage])) || task.created_at
      crew = [StageAgent.new(stage: stage, agent: mascot_agent)] # the mascot heads both views
      { to_stage: target, lane: :build, live_since: since, agents: crew, timeline_agents: crew }
    else
      intent, render_stage = open_deploy_intent(task, stage, intents)
      return nil if intent.nil?

      agents = intent_stage_agents(intent, by_slug, render_stage)
      return nil if agents.empty?

      { to_stage: target, lane: stage_lane(render_stage), live_since: intent.occurred_at,
        agents: agents, timeline_agents: deploy_timeline_agents(intent, render_stage, target, by_slug) }
    end
  end

  # The crew for the TIMELINE's live deploy card — which frames work as the real
  # pipeline transition (→ `target`, the next stage). For every lane whose live
  # intent already rides toward that next stage (the review pair → reviewed, the
  # reviewed→assembled half-state, Avi's own ship intent) this is exactly the board
  # crew. The one exception is the re-homed Steffon QA intent: it lives in the
  # assembled LANE but rides toward `shipped`, so the timeline attributes its card to
  # the ship owner (Avi) by role — NOT the QA actor — matching the eventual ship card.
  def deploy_timeline_agents(intent, render_stage, target, by_slug)
    return intent_stage_agents(intent, by_slug, target) if render_stage == target

    owner = STAGE_OWNER[target] && by_slug[STAGE_OWNER[target]]
    owner ? [StageAgent.new(stage: target, label: owner.slug, agent: owner)] : []
  end

  # True for the Steffon assembled-QA intent — recorded toward `shipped` (so the SHIP
  # supersedes it) but marked `qa` so the board renders it in the ASSEMBLED lane, not
  # the ship lane. See Release::Conductor#record_qa_intent + Task#record_intent_event.
  def qa_intent?(event)
    event.metadata.is_a?(Hash) && !!event.metadata["qa"]
  end

  # The open deploy-lane intent driving the live ticker for a non-build `stage`, plus
  # the stage it RENDERS as (its lane + avatar role). Returns [intent_or_nil, stage]:
  #   submitted → the review pair, toward `reviewed`.
  #   reviewed  → Steffon's QA, toward `assembled` — the rare half-state (a member
  #               attached for QA before its merge has flipped it to assembled).
  #   assembled → Avi's SHIP if a (non-QA) ship intent is open — he's actively
  #               shipping, so that outranks QA and renders in the SHIPPED lane; else
  #               Steffon's QA intent (marked, toward `shipped`) rendered in the
  #               ASSEMBLED lane. This is THE standard flow: by prepare time the merge
  #               already landed the assembled transition, so the QA intent can't ride
  #               toward `assembled` (it would no-op + read off the wrong stage) — it
  #               rides toward `shipped` and is re-homed to the assembled lane here.
  def open_deploy_intent(task, stage, intents)
    if stage == "assembled"
      toward_shipped = open_task_intents_for(task, "shipped", intents)
      ship = toward_shipped.reject { |e| qa_intent?(e) }.max_by { |e| [e.occurred_at, e.id.to_i] }
      return [ship, "shipped"] if ship

      qa = toward_shipped.select { |e| qa_intent?(e) }.max_by { |e| [e.occurred_at, e.id.to_i] }
      [qa, "assembled"]
    else
      target = NEXT_PIPELINE_STAGE[stage]
      [open_task_intents_for(task, target, intents).max_by { |e| [e.occurred_at, e.id.to_i] }, target]
    end
  end

  def open_task_intents_for(task, to_stage, intents)
    return task.open_intents_for(to_stage) if task.respond_to?(:open_intents_for)

    Array(intents).select { |e| e.to_stage == to_stage }
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

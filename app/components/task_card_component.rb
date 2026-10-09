# frozen_string_literal: true

# One board card: the task's title, crew, slug row, status bars, CI meter,
# stamps, latest note and footer actions.
#
#   render TaskCardComponent.new(task: task, preloads: board.preloads_for(task), crew_board: :build)
#
# Every caller builds it the same way. A page of cards takes its preloads from
# one TaskCardComponent::Board (TaskCardPreloads#load_task_cards); a single
# card, as DeploymentsBroadcaster pushes it, from Preloads.for_task. The card
# reads nothing else, so it issues no query of its own.
#
# Its public surface, which the boards and the live stream rely on:
#   root     #card-<slug>.kanban-card with data-slug, data-stage, data-agent,
#            data-apps, data-href, data-glow and, when it glows, data-stage-glow
#   slots    #ci-progress-<slug>, which a CI tick morphs in place
#   Alpine   x-show reads matchesFilter and appVisible, and the footer buttons
#            call archiveTask and deleteTask, from the page's own scope
class TaskCardComponent < ViewComponent::Base
  # What one card reads beyond its task. Every member is required, so a caller
  # cannot omit one and leave the card to look it up.
  #   agents              the roster, in board order
  #   mascot              the task's Pokemon, or nil
  #   type_enumerals      { type key => enumeral with a colour }, or nil
  #   latest_activity     the newest conversation Activity, or nil
  #   activity_count      conversation notes on the task
  #   unresolved_feedback the open qa_feedback Activity, or nil
  #   ever_blocked        whether the task ever carried a qa_feedback
  #   review_in_progress  whether a reviewer holds it now
  #   ci_progress         a Ci::CheckProgress, or nil
  #   resubmission        a Task::Resubmission
  #   agent_session       the live studio AgentSession on the task, or nil
  Preloads = Data.define(:agents, :mascot, :type_enumerals, :latest_activity, :activity_count,
                         :unresolved_feedback, :ever_blocked, :review_in_progress, :ci_progress,
                         :resubmission, :agent_session) do
    # The single-card read: one task's inputs, each looked up for that task.
    def self.for_task(task, agents: Agent.order(:position).to_a)
      activities = Activity.for_task(task).where(activity_type: Activity::TASK_CONVERSATION_TYPES).to_a
      new(
        agents: agents,
        mascot: Pokemon.find_by(slug: task.devops_field("mascot").to_s.presence),
        type_enumerals: Pokemon.type_enumerals,
        latest_activity: activities.max_by(&:created_at),
        activity_count: activities.size,
        unresolved_feedback: task.unresolved_feedback_activity,
        ever_blocked: activities.any?(&:blocking_feedback?),
        review_in_progress: task.review_in_progress?,
        ci_progress: Ci::ProgressReader.new.for_task(task),
        resubmission: task.resubmission,
        agent_session: AgentSession.live_by_task([task])[task.slug]
      )
    end
  end

  # A page of cards: the batches TaskCardPreloads loads once, split per task.
  class Board
    attr_reader :agents, :pokemon_by_slug, :type_enumerals

    def initialize(agents:, pokemon_by_slug:, type_enumerals:, latest_activities:, activity_counts:,
                   unresolved_feedback:, ever_blocked_slugs:, resubmissions:, ci_progress_by_slug:, agent_sessions:)
      @agents = agents
      @pokemon_by_slug = pokemon_by_slug
      @type_enumerals = type_enumerals
      @latest_activities = latest_activities
      @activity_counts = activity_counts
      @unresolved_feedback = unresolved_feedback
      @ever_blocked_slugs = ever_blocked_slugs
      @resubmissions = resubmissions
      @ci_progress_by_slug = ci_progress_by_slug
      @agent_sessions = agent_sessions
    end

    # `task` carries its preloaded task_events, which the review read filters in memory.
    def preloads_for(task)
      slug = task.slug
      Preloads.new(
        agents: agents,
        mascot: pokemon_by_slug[task.devops_field("mascot")],
        type_enumerals: type_enumerals,
        latest_activity: @latest_activities[slug],
        activity_count: @activity_counts[slug].to_i,
        unresolved_feedback: @unresolved_feedback[slug],
        ever_blocked: @ever_blocked_slugs.include?(slug),
        review_in_progress: task.review_in_progress?(events: task.task_events.to_a),
        ci_progress: @ci_progress_by_slug[slug],
        resubmission: @resubmissions.fetch(slug),
        agent_session: @agent_sessions[slug]
      )
    end

    def card(task, crew_board:)
      TaskCardComponent.new(task: task, preloads: preloads_for(task), crew_board: crew_board)
    end
  end

  HEX_COLOUR = /\A#[0-9a-f]{6}\z/i
  KIND_EMOJI = { "bug" => "🐛", "docs" => "📚" }.freeze
  STAMP_FORMAT = "%b %-d, %Y %-l:%M%P"
  # A session's issuer, as the soul chip's tooltip names the login.
  LOGIN_LABELS = { "task_claim" => "builder login", "review_claim" => "reviewer login" }.freeze

  # The fallback glow colour per kind, used when the mascot has no signature colour.
  GLOW_COLOURS = {
    "approval" => "#f59e0b", "review" => "#22c55e", "reviewed" => "#22d3ee", "assembled" => "#a78bfa"
  }.freeze
  # How far the glow tints the border, per cent; other kinds take the default.
  GLOW_BORDER_MIX = { "approval" => 58, "reviewed" => 52, "assembled" => 58 }.freeze
  DEFAULT_GLOW_BORDER_MIX = 46
  GLOW_SHADOWS = {
    "assembled" =>
      "0 0 0 1px color-mix(in srgb, var(--task-card-glow-color-a) 44%, transparent), " \
      "0 0 34px color-mix(in srgb, var(--task-card-glow-color-b) 38%, transparent), " \
      "0 0 82px color-mix(in srgb, var(--task-card-glow-color-a) 22%, transparent), " \
      "0 0 118px color-mix(in srgb, var(--task-card-glow-color-b) 12%, transparent)",
    "approval" =>
      "0 0 0 1px color-mix(in srgb, var(--task-card-glow-color) 46%, transparent), " \
      "0 0 26px color-mix(in srgb, var(--task-card-glow-color) 34%, transparent), " \
      "0 0 72px color-mix(in srgb, var(--task-card-glow-color) 18%, transparent)",
    "reviewed" =>
      "0 0 0 1px color-mix(in srgb, var(--task-card-glow-color) 38%, transparent), " \
      "0 0 28px color-mix(in srgb, var(--task-card-glow-color) 30%, transparent), " \
      "0 0 64px color-mix(in srgb, var(--task-card-glow-color) 16%, transparent)"
  }.freeze
  DEFAULT_GLOW_SHADOW =
    "0 0 0 1px color-mix(in srgb, var(--task-card-glow-color) 34%, transparent), " \
    "0 0 22px color-mix(in srgb, var(--task-card-glow-color) 30%, transparent), " \
    "0 0 48px color-mix(in srgb, var(--task-card-glow-color) 14%, transparent)"

  # Class strings are written out whole: Tailwind finds utilities by scanning source.
  TONE_PLAIN = "bg-surface border-subtle hover:border-primary/40 hover:bg-surface-alt"
  TONE_BLOCKED = "bg-danger/10 border-danger/40 hover:border-danger/40 hover:bg-danger/20"
  TONE_BLOCKED_PAST_SEAM = "bg-danger/10 border-subtle hover:border-primary/40 hover:bg-danger/20"
  TONE_CLEARED = "bg-warning/10 border-warning/40 hover:border-warning/40 hover:bg-warning/20"
  TONE_APPROVAL = "bg-warning/10 border-warning/40 hover:border-warning hover:bg-warning/20"

  attr_reader :task, :preloads, :crew_board

  delegate :agents, :mascot, :type_enumerals, :latest_activity, :activity_count, :unresolved_feedback,
           :ever_blocked, :review_in_progress, :ci_progress, :resubmission, :agent_session, to: :preloads
  delegate :app_emoji_badge, :ci_meter_label, :ci_meter_stage?, :claim_progress_summary, :claim_progress_title,
           :compact_created_stamp, :compact_updated_stamp, :local_review_task_path, :right_fade_style,
           :status_tone, :task_activity_box_classes, :task_path, to: :helpers

  def initialize(task:, preloads:, crew_board: :deploy)
    super()
    raise ArgumentError, "preloads: takes a TaskCardComponent::Preloads" unless preloads.is_a?(Preloads)

    @task = task
    @preloads = preloads
    @crew_board = crew_board
  end

  def slug = task.slug
  def repositories_csv = task.devops_repositories.join(",")
  def local_url = task.devops? ? task.devops_url("local") : nil
  def pr_url = task.devops? ? task.devops_url("pr") : nil
  def qa_url = task.devops? ? task.devops_url("qa") : nil
  def production_url = task.devops? ? task.devops_url("production") : nil
  def waiting_for_approval? = task.waiting_for_operator_approval?
  def archived? = task.stage == "archived"
  def kind_emoji = KIND_EMOJI[task.devops_kind]
  def created_title = "Created #{task.created_at.in_time_zone.strftime(STAMP_FORMAT)}"
  def updated_title = "Updated #{task.updated_at.in_time_zone.strftime(STAMP_FORMAT)}"
  def size_label = task.po_size == "xl" ? "XL" : task.po_size[0].upcase

  # :blocked, :cleared or :never (Task#block_state), from the preloads.
  def block_state
    @block_state ||= task.block_state(unresolved: unresolved_feedback.present?, ever_blocked: ever_blocked)
  end

  # Past the seam a block tints the card and leaves the border to the stage.
  def blocked_past_seam?
    block_state == :blocked && Task::DEPLOY_STAGES.include?(task.stage)
  end

  def tone
    case block_state
    when :blocked then blocked_past_seam? ? TONE_BLOCKED_PAST_SEAM : TONE_BLOCKED
    when :cleared then TONE_CLEARED
    else waiting_for_approval? ? TONE_APPROVAL : TONE_PLAIN
    end
  end

  # The one glow a card wears, or nil. A live reviewer outranks a waiting
  # approval: the ring is the only sign someone is on the card now, and the
  # request keeps its amber tone, its bar and its place at the top of the column.
  def glow_kind
    return @glow_kind if defined?(@glow_kind)

    @glow_kind =
      if block_state == :blocked && !blocked_past_seam? then "blocked"
      elsif review_in_progress then "review"
      elsif waiting_for_approval? then "approval"
      elsif %w[reviewed assembled].include?(task.stage) then task.stage
      end
  end

  # A review wears the engine's two-wedge ring; every other glow the border glow.
  def glow_classes
    return "studio-team-glow task-card-review-glow" if glow_kind == "review"
    return nil unless glow_kind

    ["task-card-stage-glow", "task-card-stage-glow-#{glow_kind}",
     ("studio-border-glow" unless glow_kind == "blocked")].compact.join(" ")
  end

  def mascot_colour
    return @mascot_colour if defined?(@mascot_colour)

    colour = mascot&.signature_color(type_enumerals).presence || task.devops["mascot_color"].presence
    @mascot_colour = colour.to_s.match?(HEX_COLOUR) ? colour : nil
  end

  def root_style
    [glow_style, pulse_style].compact.join(" ")
  end

  def root_classes
    "kanban-card relative #{tone} #{glow_classes} rounded-lg border p-3 cursor-pointer transition group"
  end

  def status_bars?
    waiting_for_approval? || unresolved_feedback || resubmission&.surfaced?
  end

  def claim_progress?
    task.stage == "building" && task.claim_live?
  end

  def held_from_release?
    task.stage == "reviewed" && !task.included_in_release?
  end

  def operator_window
    Devops::Windows.for_task(task, unresolved: unresolved_feedback).first
  end

  # The soul logged in to the task, as the roster's Agent; nil when logged out
  # or when the roster has no such soul.
  def soul_agent
    return nil unless agent_session

    agents.find { |agent| agent.slug == agent_session.soul }
  end

  def soul_title
    name = soul_agent&.name || agent_session.soul
    "#{name} is logged in (#{LOGIN_LABELS.fetch(agent_session.issued_by, agent_session.issued_by)})"
  end

  private

  # The crew row; blank when the task has no crew to show.
  def crew
    render("components/stage_agent_avatars", task: task, agents: agents, variant: :stack, board: crew_board,
                                             mascot: mascot, review_in_progress: review_in_progress)
  end

  # Seeded by the slug, so the pulsing bars and glows breathe out of phase across a board.
  def pulse_style
    seed = slug.to_s.each_byte.reduce(7) { |memo, byte| ((memo * 31) + byte) % 100_000 }
    "--task-pulse-delay: -#{seed % 1800}ms; --task-pulse-duration: #{1500 + (seed % 1000)}ms;"
  end

  def glow_colour
    return "#ef4444" if glow_kind == "blocked"

    mascot_colour || GLOW_COLOURS.fetch(glow_kind, "#f59e0b")
  end

  # One colour per wedge: a dual-type mascot shows both types, a single-type one repeats.
  def glow_type_colours
    return [] unless %w[assembled review].include?(glow_kind) && mascot && type_enumerals

    mascot.type_keys.filter_map { |type| type_enumerals[type]&.color.presence }
          .select { |colour| colour.to_s.match?(HEX_COLOUR) }
          .uniq
  end

  def glow_colour_a = glow_type_colours.first || glow_colour
  def glow_colour_b = glow_type_colours.second || glow_colour_a

  # The border glow's seeded offset, duration and angle; the ring and a block take none.
  def glow_motion_style
    return nil if %w[blocked review].include?(glow_kind)

    seed = slug.to_s.each_byte.reduce(0) { |memo, byte| ((memo * 33) + byte) % 10_000 }
    "--studio-border-glow-offset: #{seed % 400}%; " \
      "--studio-border-glow-duration: #{18 + (seed % 9)}s; " \
      "--studio-border-glow-angle: #{38 + (seed % 18)}deg; "
  end

  def glow_style
    return nil unless glow_kind

    if glow_kind == "review"
      return "--studio-team-glow-color: #{glow_colour_a}; --studio-team-glow-color-b: #{glow_colour_b};"
    end

    "#{glow_motion_style}" \
      "--task-card-glow-color: #{glow_colour}; " \
      "--task-card-glow-color-a: #{glow_colour_a}; " \
      "--task-card-glow-color-b: #{glow_colour_b}; " \
      "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) " \
      "#{GLOW_BORDER_MIX.fetch(glow_kind, DEFAULT_GLOW_BORDER_MIX)}%, transparent); " \
      "--task-card-glow-shadow: #{GLOW_SHADOWS.fetch(glow_kind, DEFAULT_GLOW_SHADOW)}; " \
      "border-color: var(--task-card-glow-border-color); " \
      "box-shadow: var(--task-card-glow-shadow);"
  end
end

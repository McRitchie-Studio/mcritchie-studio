# frozen_string_literal: true

# Pushes a single re-rendered board card to the /deployments board over
# ActionCable (DeploymentsChannel) when a task's stage changes (a transition
# event) or an agent starts a stage's work (an intent event), so the board
# updates live without a reload — the realtime layer on top of the agentic-intent
# data shape.
#
# The payload carries the SERVER-RENDERED card HTML (not structured data) so the
# client never re-implements the card markup — it just moves / replaces / inserts
# the node and animates. Always renders the deploy-board variant.
#
# Best-effort: a render or transport failure must NEVER break the task move/intent
# that triggered it — it's caught and logged.
class DeploymentsBroadcaster
  # TaskEvent.kind → the client-facing update type. A transition moves the card to
  # its (possibly new) column; an intent updates it in place (new ticker/avatars).
  EVENT_TYPES = { TaskEvent::TRANSITION => "stage_change", TaskEvent::INTENT => "intent" }.freeze

  def self.task_event(event)
    new(event).deliver
  rescue StandardError => e
    Rails.logger.warn("[deployments-broadcaster] non-fatal: #{e.class}: #{e.message}")
    nil
  end

  def initialize(event)
    @event = event
    @task = event.task
  end

  # The JSON message subscribers receive: the update type, the task slug + its
  # CURRENT stage (which column it belongs in), the prior stage (a move), and the
  # re-rendered card HTML.
  def payload
    {
      "type" => EVENT_TYPES.fetch(@event.kind, "stage_change"),
      "slug" => @task.slug,
      "stage" => @task.stage,
      "from_stage" => @event.from_stage,
      "html" => card_html
    }
  end

  def deliver
    return nil if @task.nil?

    message = payload
    ActionCable.server.broadcast(DeploymentsChannel::STREAM, message)
    message
  end

  private

  # Render exactly the partial the board loop renders, for this one task, as the
  # deploy-board card. Path/helper-only (no request), so it's safe from a job /
  # after_commit context.
  def card_html
    ApplicationController.render(
      partial: "tasks/task_card",
      locals: {
        task: @task,
        agents: Agent.order(:position).to_a,
        crew_board: :deploy,
        mascot: Pokemon.find_by(slug: @task.devops_field("mascot").to_s.presence),
        latest_activity: activities.recent.first,
        activity_count: activities.count
      }
    )
  end

  def activities
    @activities ||= Activity.for_task(@task).where(activity_type: Activity::TASK_CONVERSATION_TYPES)
  end
end

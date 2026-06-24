# frozen_string_literal: true

# Pushes a single re-rendered board card to the /deployments board over Turbo
# Streams when a task's stage changes (a transition) or an agent starts a stage's
# work (an intent), so the board updates live without a reload.
#
# It broadcasts the SAME `tasks/_task_card` partial the board loop renders, as a
# Turbo Stream action chosen by the event:
#   intent / same-column change          → REPLACE the card in place
#   cross-column stage move              → REMOVE the old card + PREPEND a fresh one
#   brand-new task (genesis)             → PREPEND to the Designed column
#   leaves the active board (→ archived) → REMOVE
# Subscribers run `turbo_stream_from "deployments"`; Turbo patches the DOM and a
# MutationObserver on the board animates the result + refreshes the column counts.
#
# Every broadcast is wrapped in Studio::Cable.safe_broadcast so a cable/adapter
# failure can NEVER break the task write that triggered it — the SEV-1 guard, now
# shared in studio-engine (rescues StandardError AND ScriptError/Gem::LoadError).
class DeploymentsBroadcaster
  STREAM = "deployments"
  PARTIAL = "tasks/task_card"
  # The stages the deploy board shows as columns. `blocked` rides the Building
  # column; `archived` (or anything off this list) means the card left the board.
  BOARD_ZONES = Task::DEPLOYMENTS_BOARD_STAGES

  # Wrap the WHOLE operation (resolve + render + broadcast) in the engine's
  # safe_broadcast so nothing — not even a lookup or render error — can escape the
  # after_commit and break the task write (the SEV-1 guard, ScriptError included).
  def self.task_event(event)
    Studio::Cable.safe_broadcast { new(event).deliver }
  end

  def initialize(event)
    @event = event
    @task = event.task
  end

  def deliver
    return nil if @task.nil?

    broadcast
  end

  private

  # One Turbo Stream action, picked from the event kind + the from/to columns.
  def broadcast
    if left_board?
      remove_card           # → archived: drop it from the active board
    elsif new_card?
      prepend_card          # genesis: a brand-new card at the top of Designed
    elsif @event.intent? || same_zone?
      replace_card          # in place: intent ticker, or a building↔blocked re-tint
    else
      move_card             # cross-column move: remove the old card, prepend a fresh one
    end
  end

  def replace_card
    Turbo::StreamsChannel.broadcast_replace_to(STREAM, target: card_id, partial: PARTIAL, locals: card_locals)
  end

  def prepend_card
    Turbo::StreamsChannel.broadcast_prepend_to(STREAM, target: dropzone_id, partial: PARTIAL, locals: card_locals)
  end

  def remove_card
    Turbo::StreamsChannel.broadcast_remove_to(STREAM, target: card_id)
  end

  def move_card
    remove_card
    prepend_card
  end

  def card_id
    "card-#{@task.slug}"
  end

  def dropzone_id
    "dropzone-#{zone(@task.stage)}"
  end

  # The on-board column a stage lives in (blocked → the Building column).
  def zone(stage)
    stage == "blocked" ? "building" : stage
  end

  def left_board?
    !BOARD_ZONES.include?(zone(@task.stage))
  end

  def new_card?
    @event.transition? && @event.from_stage.nil?
  end

  def same_zone?
    zone(@event.from_stage) == zone(@task.stage)
  end

  # The same locals the board loop renders the card with — the deploy-board variant.
  def card_locals
    {
      task: @task,
      agents: Agent.order(:position).to_a,
      crew_board: :deploy,
      mascot: Pokemon.find_by(slug: @task.devops_field("mascot").to_s.presence),
      latest_activity: activities.recent.first,
      activity_count: activities.count
    }
  end

  def activities
    @activities ||= Activity.for_task(@task).where(activity_type: Activity::TASK_CONVERSATION_TYPES)
  end
end

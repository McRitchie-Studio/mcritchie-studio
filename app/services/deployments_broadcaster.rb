# frozen_string_literal: true

# Pushes a single re-rendered board card to the /deployments board over Turbo
# Streams when a task's stage changes (a transition) or an agent starts a stage's
# work (an intent), so the board updates live without a reload.
#
# It broadcasts the SAME `tasks/_task_card` partial the board loop renders, as a
# Turbo Stream action chosen by the event:
#   intent                               → REPLACE the card in place
#   cross-column stage move              → REMOVE + PREPEND in one ordered payload
#   building↔blocked stage move          → REMOVE + PREPEND into Building
#   brand-new task (genesis)             → PREPEND to the Designed column
#   leaves the active board (→ archived) → REMOVE
# Subscribers run `turbo_stream_from "deployments"`; Turbo patches the DOM and a
# MutationObserver on the board animates the result + refreshes the column counts.
#
# Every broadcast is wrapped in Studio::Cable.safe_broadcast so a cable/adapter
# failure can NEVER break the task write that triggered it — the SEV-1 guard, now
# shared in studio-engine (rescues StandardError AND ScriptError/Gem::LoadError).
class DeploymentsBroadcaster
  include Turbo::Streams::ActionHelper

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

  # A task was destroyed — drop its card from the live board for every viewer. A
  # `destroy` fires no TaskEvent (so #task_event never runs), hence this separate
  # entry point, called from Task's after_destroy_commit. Guarded like the rest.
  def self.task_removed(slug)
    Studio::Cable.safe_broadcast do
      Turbo::StreamsChannel.broadcast_stream_to(
        STREAM,
        content: ApplicationController.helpers.turbo_stream_action_tag(
          :remove,
          target: "card-#{slug}",
          data: { exit_action: "delete" }
        )
      )
    end
  end

  # Re-render the Next + Last release modules to every /deployments viewer after a
  # release state change (open / assemble / ship / abandon, or a mascot stamp), so
  # the cards reflect Release.current / Release.last_shipped with no reload. Two
  # REPLACE actions targeting the stable #current-release / #last-release slots; the
  # board's LiveBoardFx flashes each swapped slot (a subtle glow on Next, a
  # celebratory burst on the just-shipped Last). Computed fresh from the singleton —
  # on a ship, Release.current is nil so Next re-renders its "none active" empty
  # card. Called from Release#after_save_commit and guarded by safe_broadcast so a
  # cable failure can NEVER break the release write that triggered it (SEV-1 guard).
  def self.release_modules
    Studio::Cable.safe_broadcast do
      Turbo::StreamsChannel.broadcast_replace_to(
        STREAM, target: "current-release",
        partial: "tasks/current_release", locals: { release: Release.current }
      )
      Turbo::StreamsChannel.broadcast_replace_to(
        STREAM, target: "last-release",
        partial: "tasks/last_release", locals: { release: Release.last_shipped }
      )
    end
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

  # One websocket payload, picked from the event kind + the from/to columns.
  def broadcast
    if left_board?
      remove_card           # → archived: drop it from the active board
    elsif new_card?
      prepend_card          # genesis: a brand-new card at the top of Designed
    elsif @event.intent? || @event.checkpoint?
      replace_card          # in place: intent ticker / lifecycle checkpoint
    else
      move_card             # stage move: remove the old card, prepend a fresh one
    end
  end

  def replace_card
    Turbo::StreamsChannel.broadcast_replace_to(STREAM, target: card_id, partial: PARTIAL, locals: card_locals)
  end

  def prepend_card
    Turbo::StreamsChannel.broadcast_prepend_to(STREAM, target: dropzone_id, partial: PARTIAL, locals: card_locals)
  end

  def remove_card
    Turbo::StreamsChannel.broadcast_stream_to(
      STREAM,
      content: turbo_stream_action_tag(:remove, target: card_id, data: { exit_action: "archive" })
    )
  end

  def move_card
    Turbo::StreamsChannel.broadcast_stream_to(STREAM, content: move_stream_content)
  end

  def move_stream_content
    [
      turbo_stream_action_tag(:remove, target: card_id),
      turbo_stream_action_tag(:prepend, target: dropzone_id, template: rendered_card)
    ].join
  end

  def rendered_card
    ApplicationController.render(partial: PARTIAL, formats: [:html], locals: card_locals)
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

  # The same locals the board loop renders the card with — the deploy-board variant.
  # The task's conversation activities are loaded ONCE (see #activities) and the
  # three activity-derived locals — latest, count, and the ever_blocked block-tone
  # flag — are all read from that in-memory set. Passing +ever_blocked+ preloaded
  # (the board loop's @ever_blocked_slugs equivalent) keeps Task#block_state from
  # self-querying ever_blocked? on this single-card render.
  def card_locals
    {
      task: @task,
      agents: Agent.order(:position).to_a,
      crew_board: :deploy,
      mascot: Pokemon.find_by(slug: @task.devops_field("mascot").to_s.presence),
      type_enumerals: type_enumerals,
      latest_activity: activities.max_by(&:created_at),
      activity_count: activities.size,
      ever_blocked: activities.any?(&:blocking_feedback?),
      unresolved_feedback: @task.unresolved_feedback_activity,
      review_in_progress: @task.review_in_progress?
    }
  end

  # The task's conversation activities (comment/clarification/qa_feedback/handoff),
  # loaded once into memory so #card_locals derives latest/count/ever_blocked from
  # the same set instead of firing a separate query for each.
  def activities
    @activities ||= Activity.for_task(@task)
                            .where(activity_type: Activity::TASK_CONVERSATION_TYPES)
                            .to_a
  end

  def type_enumerals
    @type_enumerals ||= Pokemon.type_enumerals
  end
end

# Live Turbo Stream updates for the /agents/activities feed — the activity-feed analogue
# of DeploymentsBroadcaster. Called from AgentActivity/AgentAction after_*_commit
# callbacks; every send is wrapped in Studio::Cable.safe_broadcast so a dead cable / a
# render or lookup error can NEVER escape into (and break) the DB write on the capture
# hot path. Renders the SAME agents/_activity_row + agents/_activity_action_row partials
# the page renders, with locals built by the shared ActivityFeed concern (dual render
# paths kept identical). The feed is newest-first, so a new activity inserts right after
# the thead; the websocket is purely ADDITIVE — it never re-paginates or re-counts.
class ActivitiesBroadcaster
  include ActivityFeed

  STREAM       = "agents_activities"
  HEAD_TARGET  = "aa-activities-head"          # thead id — new activities insert after it
  ACTIVITY_ROW = "agents/activity_row"
  ACTION_ROW   = "agents/activity_action_row"

  class << self
    def activity_created(activity) = safe { new.deliver_activity_created(activity) }
    def activity_updated(activity) = safe { new.deliver_activity_updated(activity) }
    def action_created(action)     = safe { new.deliver_action_created(action) }
    def action_updated(action)     = safe { new.deliver_action_updated(action) }

    private

    def safe(&block) = Studio::Cable.safe_broadcast(&block)
  end

  # A new narrated activity → its tbody, inserted right after the thead (top of the feed).
  def deliver_activity_created(activity)
    Turbo::StreamsChannel.broadcast_after_to(
      STREAM, target: HEAD_TARGET, partial: ACTIVITY_ROW, locals: activity_row_locals(activity)
    )
  end

  # An updated activity (outcome/close/etc.) → replace its whole tbody in place. The
  # flash-on-update fires client-side for the aa-activity-<id> replace.
  def deliver_activity_updated(activity)
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM, target: "aa-activity-#{activity.id}", partial: ACTIVITY_ROW, locals: activity_row_locals(activity)
    )
  end

  # A new raw action → append its row into its activity's drill-down (additive; the
  # per-activity action count is intentionally not re-synced). First clears the "no raw
  # actions" placeholder (a no-op once actions already exist).
  def deliver_action_created(action)
    activity_id = action.agent_activity_id
    return unless activity_id # unlabeled actions never appear on this feed

    Turbo::StreamsChannel.broadcast_remove_to(STREAM, target: "aa-empty-#{activity_id}")
    Turbo::StreamsChannel.broadcast_append_to(
      STREAM, target: "aa-activity-#{activity_id}", partial: ACTION_ROW, locals: action_row_locals(action)
    )
  end

  # An updated action (outcome/tokens/cost/summary) → replace its row + flash.
  def deliver_action_updated(action)
    return unless action.agent_activity_id

    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM, target: "aa-action-#{action.id}", partial: ACTION_ROW, locals: action_row_locals(action)
    )
  end
end

# Live Turbo Stream updates for the /agents/activities feed — the activity-feed analogue
# of DeploymentsBroadcaster. Called from AgentActivity/AgentAction after_*_commit
# callbacks; every send is wrapped in Studio::Cable.safe_broadcast so a dead cable / a
# render or lookup error can NEVER escape into (and break) the DB write on the capture
# hot path. Renders the SAME agents/_activity_row partial the page renders (turn-grouped
# drill-down included), with locals built by the shared ActivityFeed concern (dual render
# paths kept identical). The feed is newest-first, so a new activity inserts right after
# the thead; the websocket is purely ADDITIVE — it never re-paginates or re-counts.
class ActivitiesBroadcaster
  include ActivityFeed

  STREAM         = "agents_activities"
  SESSION_PREFIX = "#{STREAM}:session:"
  HEAD_TARGET    = "aa-activities-head"          # thead id — new activities insert after it
  ACTIVITY_ROW   = "agents/activity_row"

  class << self
    def stream_for_session(session_id)
      id = session_id.to_s.strip
      return nil if id.blank?

      "#{SESSION_PREFIX}#{id}"
    end

    def streams_for_filters(session_ids)
      ids = Array(session_ids).map { |id| id.to_s.strip }.reject(&:blank?).uniq
      return [STREAM] if ids.empty?

      ids.map { |id| stream_for_session(id) }
    end

    def activity_created(activity) = safe { new.deliver_activity_created(activity) }
    def activity_updated(activity) = safe { new.deliver_activity_updated(activity) }
    def action_created(action)     = safe { new.deliver_action_created(action) }
    def action_updated(action)     = safe { new.deliver_action_updated(action) }

    private

    def safe(&block) = Studio::Cable.safe_broadcast(&block)
  end

  # A new narrated activity → its tbody, inserted right after the thead (top of the feed).
  def deliver_activity_created(activity)
    broadcast_to_activity_streams(
      activity, :broadcast_after_to, target: HEAD_TARGET, partial: ACTIVITY_ROW, locals: activity_row_locals(activity)
    )
  end

  # An updated activity (outcome/close/etc.) → replace its whole tbody in place. The
  # flash-on-update fires client-side for the aa-activity-<id> replace.
  def deliver_activity_updated(activity)
    broadcast_to_activity_streams(
      activity, :broadcast_replace_to, target: "aa-activity-#{activity.id}",
      partial: ACTIVITY_ROW, locals: activity_row_locals(activity)
    )
  end

  # A new raw action → the turn-grouped drill-down must RECOMPUTE (a new action can start
  # a new turn or join a fan-out, and it shifts the reasoning/TOTAL reconciliation), so
  # re-render the activity's WHOLE tbody rather than append a lone action row. The tbody
  # re-render also drops the "no raw actions" placeholder for free.
  def deliver_action_created(action)
    activity = action.agent_activity
    return unless activity # unlabeled actions never appear on this feed

    deliver_activity_updated(activity)
  end

  # An updated action (outcome/tokens/cost/summary) → same: re-render the tbody so the
  # turn row and the reconciliation reflect the change.
  def deliver_action_updated(action)
    activity = action.agent_activity
    return unless activity

    deliver_activity_updated(activity)
  end

  private

  def broadcast_to_activity_streams(activity, method, **options)
    activity_streams(activity).each do |stream|
      Turbo::StreamsChannel.public_send(method, stream, **options)
    end
  end

  def activity_streams(activity)
    [STREAM, self.class.stream_for_session(activity.session_id)].compact
  end
end

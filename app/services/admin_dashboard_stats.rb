# The four cards at the top of /admin/dashboard, each one line of counts that
# leads to the page behind it.
#
#   stats = AdminDashboardStats.new(viewer: current_user)
#   stats.users        # total, last_new_at, new_this_week
#   stats.sessions     # this_week (admins not counted), last_user, last_seen_at
#   stats.agents       # total, pending
#   stats.applications # live, pending
class AdminDashboardStats
  WINDOW = 7.days

  Users = Data.define(:total, :last_new_at, :new_this_week)
  Sessions = Data.define(:this_week, :last_user, :last_seen_at)
  Agents = Data.define(:total, :pending)
  Applications = Data.define(:live, :pending)

  def initialize(viewer:, now: Time.current)
    @viewer = viewer
    @now = now
  end

  def users
    Users.new(total: User.count, last_new_at: User.maximum(:created_at),
              new_this_week: User.where(created_at: since..).count)
  end

  # Zero and nobody until the engine that records sessions is here and migrated.
  def sessions
    return Sessions.new(this_week: 0, last_user: nil, last_seen_at: nil) unless sessions_recorded?

    scope = Studio::UserSession.non_admin
    last = scope.includes(:user).recent.first
    Sessions.new(this_week: scope.where(last_seen_at: since..).count, last_user: last&.user, last_seen_at: last&.last_seen_at)
  end

  def agents
    Agents.new(total: Agent.count, pending: AgentSetup.open_setups.count)
  end

  def applications
    list = ApplicationsWatchList.build(AppOwnership.visible_apps(@viewer).to_a, admin: true)
    Applications.new(live: list.live.size, pending: list.pending.size)
  end

  private

  def since = @now - WINDOW

  def sessions_recorded? = defined?(Studio::UserSession) && Studio::UserSession.available?
end

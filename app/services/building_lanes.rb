require "zlib"

# Concurrent task lanes per package tier (docs/agents/system/client-pipeline.md;
# plan: Phase 8 of .agents/epics/domain-agents.md).
#
# A client app may have at most `building_lanes` of its tasks in `building` at
# once (config/workspace_packages.yml: Vibe 1, Builder 2, Pro 3, Team 4,
# Enterprise blank = unlimited). Extra work waits in `designed`, in board order.
# The app's tier is `apps.package_tier`. The hub itself and any app with no tier
# are internal and never capped.
#
#   BuildingLanes.status(app)        # => Status(cap: 2, in_use: 1, …) "1 of 2 lanes in use"
#   BuildingLanes.refusal_for(task)  # => nil, or the message Task's claim validation adds
#
# The cap binds the CLAIM (Task#claims_a_building_lane?): a create at `building`,
# a move into it from `designed`, `shipped` or `archived`, a first move of a task
# that was never claimed, and a client repo added to a task already building. A
# rework block bounces a claimed task back to `building` without a claim, and a
# re-claim of a task already building takes no new lane, so neither is refused.
module BuildingLanes
  # Apps that are never capped whatever their tier: the hub's own work.
  INTERNAL_APPS = %w[mcritchie-studio].freeze

  Status = Struct.new(:app, :package, :in_use, keyword_init: true) do
    def cap = package&.building_lanes
    def capped? = !cap.nil?
    def full? = capped? && in_use >= cap
    def tier_name = package&.name
    # Lanes held past the cap: a send-back keeps its lane, and a downgrade does
    # not evict work, so in_use can run over for a while. 0 when uncapped.
    def over = capped? ? [ in_use - cap, 0 ].max : 0

    # "2 of 3 lanes in use"; "3 lanes in use on a 2-lane plan" past the cap; or
    # "2 lanes in use" when unlimited.
    def label
      return "#{in_use} lanes in use on a #{cap}-lane plan" if over.positive?

      noun = (capped? ? cap : in_use) == 1 ? "lane" : "lanes"
      capped? ? "#{in_use} of #{cap} #{noun} in use" : "#{in_use} #{noun} in use"
    end
  end

  module_function

  # The tier whose cap binds this app, or nil when the app is uncapped (internal,
  # no tier, an unknown tier key, or a tier with no cap).
  def package_for(app)
    return nil if app.nil? || INTERNAL_APPS.include?(app.slug) || app.package_tier.blank?

    WorkspacePackage.find(app.package_tier)
  end

  def cap_for(app) = package_for(app)&.building_lanes

  def building_scope(app_slug) = Task.for_repository(app_slug).where(stage: "building")

  def status(app) = Status.new(app: app, package: package_for(app), in_use: building_scope(app.slug).count)

  # nil when `task` may take a lane; else one sentence naming the app, its tier,
  # the lanes in use and the upgrade. Checks every tiered app the task names, or
  # only the slugs in `only` (a repo added to a task already building).
  #
  # `lock: true` (the claim validation, inside the save's transaction) takes a
  # transaction-scoped advisory lock per capped app before counting, so two
  # concurrent claims serialize: the second counts after the first commits and
  # cannot overfill the cap by one. Locks are taken in a fixed order (app
  # position, then name), so two multi-app claims cannot deadlock.
  def refusal_for(task, only: nil, lock: false)
    slugs = only.nil? ? task.devops_repositories : task.devops_repositories & Array(only)
    return nil if slugs.empty?

    App.where(slug: slugs).order(:position, :name).each do |app|
      package = package_for(app)
      next unless (cap = package&.building_lanes)

      lock_lanes!(app.slug) if lock
      busy = building_scope(app.slug).where.not(id: task.id).order(:started_at).pluck(:slug)
      next if busy.size < cap

      return refusal_message(app, package, busy)
    end
    nil
  end

  # The advisory-lock key namespace for building lanes ("BL").
  LOCK_NAMESPACE = 0x424C

  # Holds until the surrounding transaction ends (a no-op outside one).
  def lock_lanes!(app_slug)
    key = Zlib.crc32("building_lanes:#{app_slug}") & 0x7fffffff
    Task.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{key})")
  end

  def refusal_message(app, package, busy)
    upgrade = next_tier(package)
    more = if upgrade
      upgrade.building_lanes ? "upgrade to #{upgrade.name} for #{upgrade.building_lanes} lanes" : "upgrade to #{upgrade.name} for unlimited lanes"
    else
      "talk to us about more lanes"
    end
    "#{app.name} is on the #{package.name} tier: #{busy.size} of #{package.building_lanes} building " \
      "#{package.building_lanes == 1 ? 'lane' : 'lanes'} in use (#{busy.join(', ')}). This task waits in designed " \
      "until one is submitted; or #{more} (/packages)."
  end

  # The next tier up the ladder with more lanes than `package`, or nil.
  def next_tier(package)
    ladder = WorkspacePackage.all
    above = ladder.drop(ladder.index { |pkg| pkg.key == package.key }.to_i + 1)
    above.find { |pkg| pkg.building_lanes.nil? || pkg.building_lanes > package.building_lanes }
  end
end

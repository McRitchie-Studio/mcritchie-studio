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
# The cap binds the CLAIM: a move from `designed` (or a create) into `building`.
# A rework block bounces a submitted task back to `building` without a claim, and
# a re-claim of a task already building takes no new lane, so neither is refused.
module BuildingLanes
  # Apps that are never capped whatever their tier: the hub's own work.
  INTERNAL_APPS = %w[mcritchie-studio].freeze

  Status = Struct.new(:app, :package, :in_use, keyword_init: true) do
    def cap = package&.building_lanes
    def capped? = !cap.nil?
    def full? = capped? && in_use >= cap
    def tier_name = package&.name

    # "2 of 3 lanes in use", or "2 lanes in use" when unlimited.
    def label
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
  # the lanes in use and the upgrade. Checks every tiered app the task names.
  def refusal_for(task)
    slugs = task.devops_repositories
    return nil if slugs.empty?

    App.where(slug: slugs).order(:position, :name).each do |app|
      package = package_for(app)
      next unless (cap = package&.building_lanes)

      busy = building_scope(app.slug).where.not(id: task.id).order(:started_at).pluck(:slug)
      next if busy.size < cap

      return refusal_message(app, package, busy)
    end
    nil
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

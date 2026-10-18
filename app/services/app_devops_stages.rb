# The client-facing devops of one app: the three stage pills on the status card
# of /applications/:slug/chat (.agents/epics/build-with-ray-v2.md, section 6).
#
#   AppDevopsStages.for_app(app)                  # => [Stage, Stage, Stage]
#   AppDevopsStages.from("assembled")             # the mapping alone, for tests
#
# The stages come from the app's BUILD TASK (the board task AppLaunch opens,
# found through the request that claimed the subdomain):
#
#   designed · building · submitted · reviewed    Building is live
#   assembled                                     Building done, Releasing live
#   assembled, its release deploying production   Releasing done, Deploying live
#   shipped                                       all three done
#
# The board has no `shipping` task stage: a task waits on `assembled` while its
# release ships, so Deploying reads the release's own timeline
# (Release#current_stage "prod_deploying"). An archived task shows nothing live.
# An app with no build task (one of our own, live before /build existed) shows
# all three done.
class AppDevopsStages
  Stage = Struct.new(:key, :label, :state, keyword_init: true) do
    def done? = state == :done
    def live? = state == :live
  end

  STAGES = { "building" => "Building", "releasing" => "Releasing", "deploying" => "Deploying" }.freeze
  BUILDING_TASK_STAGES = %w[designed building submitted reviewed].freeze
  DEPLOYING_RELEASE_STAGES = %w[prod_deploying].freeze

  def self.for_app(app)
    task = build_task(app)
    return from("shipped") if task.nil?

    from(task.stage, release_stage: (task.release&.current_stage if task.stage == "assembled"))
  end

  # The newest build task for the app's subdomain, or nil.
  def self.build_task(app)
    slug = AppRequest.where(subdomain: app.slug).where.not(task_slug: nil).order(:id).last&.task_slug
    slug && Task.find_by(slug: slug)
  end

  # The pills for a task stage: each :done, :live or :pending.
  def self.from(task_stage, release_stage: nil)
    live = live_key(task_stage.to_s, release_stage.to_s)
    keys = STAGES.keys
    at = live == :all_done ? keys.size : keys.index(live)
    keys.each_with_index.map do |key, index|
      state = if at.nil? then :pending
              elsif index < at then :done
              elsif index == at then :live
              else :pending
              end
      Stage.new(key: key, label: STAGES[key], state: state)
    end
  end

  def self.live_key(task_stage, release_stage)
    return :all_done if task_stage == "shipped"
    return "building" if BUILDING_TASK_STAGES.include?(task_stage)
    return nil unless task_stage == "assembled"

    DEPLOYING_RELEASE_STAGES.include?(release_stage) ? "deploying" : "releasing"
  end
  private_class_method :live_key
end

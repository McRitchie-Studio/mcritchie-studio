# The client-facing devops of one app: the three stage pills on the status card
# of /applications/:slug/chat, and the short list of tasks under them
# (.agents/epics/build-with-ray-v2.md, section 6; task app-card-live-tasks).
#
#   AppDevopsStages.board_for(app, admin: false)   # => Board(stages:, items:, total:)
#   AppDevopsStages.for_app(app)                   # => [Stage, Stage, Stage]
#   AppDevopsStages.from("assembled")              # one task's mapping, for tests
#
# THE TASKS. Every OPEN board task for the app (not shipped, not archived):
#   - the tasks whose devops.repositories name the app's repo (an App slug is its
#     repo slug: config/apps.yml, and AppLaunch's build task names [<subdomain>]);
#   - the tasks opened from this app's chat by a confirmed proposal
#     (devops.source_thread is the chat page, AgentProposal#thread_url);
#   - the app's BUILD TASK (the board task AppLaunch opens, found through the
#     request that claimed the subdomain), whatever repos it names.
# One query reads them (plus one for their releases), newest activity first.
#
# THE LANES. Each task sits in one:
#
#   designed · building · submitted · reviewed    Building
#   assembled                                     Releasing
#   assembled, its release deploying production   Deploying
#
# The board has no `shipping` task stage: a task waits on `assembled` while its
# release ships, so Deploying reads the release's own timeline
# (Release#current_stage "prod_deploying"). A task whose release has shipped, or
# that carries completed_at, is done and counts nowhere.
#
# THE PILLS. A lane with tasks is live and carries its count. A lane with none is
# muted, except that while the app's own build task is in flight the lanes it has
# passed keep their check (the launch's progress, as before). With nothing in
# flight every pill is muted and the card says "Nothing in progress": never three
# checks that read as finished work.
#
# THE SUB-LABELS (task app-card-stage-labels, Alex 2026-10-19). A live pill also
# says where its work actually is, read from the lane's MOST ADVANCED task (the
# newest among equals), and how long that step usually has left (Eta):
#
#   designed    Prepping          in line: nobody is building it yet
#   building    Building          a builder holds it (On hold while blocked)
#   submitted   Reviewing         its PR is in review
#   reviewed    Approved          merged, waiting for a release
#   assembled   On QA             on a release, in QA
#   deploying   Going live        its release is deploying production
#
# Each list row says the same for its own task ("Prepping · waiting for a
# builder"). THE PREVIEW SEAM: once a task's first version is live on its
# preview host, the host's publish (task client-app-host) records a
# `preview_ready` CHECKPOINT TaskEvent on it; a task past `designed` and still
# in the Building lane then reads "Preview ready", with no ETA.
class AppDevopsStages
  # `sub_label` and `eta` (an Eta::Estimate, or nil) are set on a live pill only.
  Stage = Struct.new(:key, :label, :state, :count, :sub_label, :eta, keyword_init: true) do
    def done? = state == :done
    def live? = state == :live
  end

  # One line of the card's list. `slug` is set for an admin only; an owner's
  # title has been through ClientPipeline's sanitizer. `status` is the task's
  # sub-label and ETA phrase, "Prepping · waiting for a builder".
  Item = Struct.new(:title, :lane, :slug, :at, :sub_label, :eta, keyword_init: true) do
    def status = [ sub_label, eta&.phrase ].compact.join(" · ")
  end

  Board = Struct.new(:stages, :items, :total, keyword_init: true) do
    def idle? = total.zero?
    def more = total - items.size
  end

  STAGES = { "building" => "Building", "releasing" => "Releasing", "deploying" => "Deploying" }.freeze
  BUILDING_TASK_STAGES = %w[designed building submitted reviewed].freeze
  DEPLOYING_RELEASE_STAGES = %w[prod_deploying].freeze
  LIST_LIMIT = 5
  COLUMNS = %i[id slug title stage release_slug completed_at updated_at created_at
               started_at submitted_at reviewed_at assembled_at blocked_at].freeze
  # A task's step: its stage, or Eta::DEPLOYING while its release deploys.
  # Ordered: the furthest-along step leads its lane's pill.
  STEPS = (BUILDING_TASK_STAGES + %w[assembled] + [ Eta::DEPLOYING ]).freeze
  SUB_LABELS = { "designed" => "Prepping", "building" => "Building", "submitted" => "Reviewing",
                 "reviewed" => "Approved", "assembled" => "On QA", Eta::DEPLOYING => "Going live" }.freeze
  ON_HOLD = "On hold".freeze
  PREVIEW_READY = "Preview ready".freeze
  PREVIEW_READY_EVENT = "preview_ready".freeze

  # The status card's model: the pills, the newest `limit` tasks, the total.
  def self.board_for(app, admin: false, limit: LIST_LIMIT)
    launch = build_task_slug(app)
    placed = open_tasks(app, launch_slug: launch).filter_map do |task|
      lane = lane_for(task)
      [ task, lane ] if lane
    end

    progress = Progress.new(placed, listed: placed.first(limit))
    Board.new(stages: stages_for(placed, launch && placed.find { |task, _| task.slug == launch }, progress),
              items: items_for(app, placed.first(limit), progress, admin: admin, launch_slug: launch), total: placed.size)
  end

  # The step a placed task is on (see STEPS).
  def self.step_for(task, lane) = lane == Eta::DEPLOYING ? Eta::DEPLOYING : task.stage.to_s

  # The sub-label for a task on a step (see THE SUB-LABELS).
  def self.sub_label_for(step, blocked: false, preview_ready: false)
    return ON_HOLD if step == "building" && blocked
    return PREVIEW_READY if preview_ready && BUILDING_TASK_STAGES.include?(step) && step != "designed"

    SUB_LABELS[step]
  end

  # Each task's sub-label and ETA, read once for the card: the lane heads and
  # the listed rows share one median query, one launcher read (only when a
  # designed task shows) and one preview read.
  class Progress
    def initialize(placed, listed:, now: Time.current)
      @now = now
      @heads = placed.group_by(&:last).transform_values do |pairs|
        pairs.each_with_index.max_by { |(task, lane), index| [ STEPS.index(AppDevopsStages.step_for(task, lane)).to_i, -index ] }.first
      end
      shown = (@heads.values + listed).uniq { |task, _| task.slug }
      steps = shown.map { |task, lane| AppDevopsStages.step_for(task, lane) }
      @medians = Eta.medians(steps)
      @launcher = steps.include?("designed") && Eta.launcher_live?(now: now)
      @previews = previews(shown.map { |task, _| task.slug })
    end

    # [sub_label, eta] for the lane's head task, or nil for an empty lane.
    def for_lane(key)
      pair = @heads[key]
      pair && for_task(*pair)
    end

    def for_task(task, lane)
      step = AppDevopsStages.step_for(task, lane)
      label = AppDevopsStages.sub_label_for(step, blocked: task.blocked_at.present?, preview_ready: @previews.include?(task.slug))
      eta = (Eta.estimate(step, entered_at: entered_at(task, step), medians: @medians, launcher: @launcher, now: @now) if label == SUB_LABELS[step])
      [ label, eta ]
    end

    private

    def entered_at(task, step)
      step == Eta::DEPLOYING ? task.release&.prod_deploy_started_at : task.public_send(Eta::ENTERED_AT.fetch(step))
    end

    def previews(slugs)
      return Set.new if slugs.empty?

      TaskEvent.checkpoints.where(task_slug: slugs, to_stage: PREVIEW_READY_EVENT).distinct.pluck(:task_slug).to_set
    end
  end

  def self.for_app(app) = board_for(app, limit: 0).stages

  # Every open task for the app, newest activity first (see THE TASKS).
  def self.open_tasks(app, launch_slug: nil)
    open = Task.where.not(stage: %w[shipped archived]).where(completed_at: nil)
    chat = "%/applications/#{Task.sanitize_sql_like(app.slug)}/chat"
    scope = open.for_repository(app.slug)
                .or(open.where("tasks.metadata -> 'devops' ->> 'source_thread' LIKE ?", chat))
    scope = scope.or(open.where(slug: launch_slug)) if launch_slug
    scope.select(*COLUMNS)
         .select("tasks.metadata -> 'devops' -> 'repositories' AS card_repositories")
         .preload(:release).order(updated_at: :desc, id: :desc).to_a
  end

  # The lane key a task sits in, or nil when it is done (its release shipped).
  def self.lane_for(task)
    return nil if shipped?(task)

    key = live_key(task.stage.to_s, (task.release&.current_stage.to_s if task.stage == "assembled"))
    key.is_a?(String) ? key : nil
  end

  # Shipped, whatever the task column says now: archive-shipped moves a shipped
  # task to `archived` (completed_at stays), and a release can ship before its
  # members are moved (Release#resumable_member_ship).
  def self.shipped?(task)
    task.completed_at.present? || (%w[assembled archived].include?(task.stage) && task.release&.shipped?)
  end

  # The slug of the newest build task for the app's subdomain, or nil.
  def self.build_task_slug(app)
    AppRequest.where(subdomain: app.slug).where.not(task_slug: nil).order(:id).last&.task_slug
  end

  # The newest build task for the app's subdomain, or nil.
  def self.build_task(app)
    slug = build_task_slug(app)
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
      Stage.new(key: key, label: STAGES[key], state: state, count: 0)
    end
  end

  # The pills for the placed [task, lane] pairs (see THE PILLS). `launch` is the
  # build task's pair while it is in flight, else nil.
  def self.stages_for(placed, launch, progress)
    counts = placed.map(&:last).tally
    base = launch ? from(launch.first.stage, release_stage: (launch.first.release&.current_stage if launch.first.stage == "assembled")) : nil
    STAGES.each_with_index.map do |(key, label), index|
      count = counts[key].to_i
      state = if count.positive? then :live
              elsif base&.dig(index)&.done? then :done
              else :pending
              end
      sub_label, eta = progress.for_lane(key) if state == :live
      Stage.new(key: key, label: label, state: state, count: count, sub_label: sub_label, eta: eta)
    end
  end

  # An owner reads the app's build task ("Build Launch App <subdomain>", the
  # board's name for it) as "Launching <App name>".
  def self.items_for(app, placed, progress, admin:, launch_slug: nil)
    return [] if placed.empty?

    scrubber = ClientPipeline::Scrubber.new(app) unless admin
    placed.map do |task, lane|
      title = if admin then task.title
              elsif task.slug == launch_slug then "Launching #{app.name}"
              else owner_title(task, app, scrubber)
              end
      sub_label, eta = progress.for_task(task, lane)
      Item.new(title: title, lane: STAGES.fetch(lane), slug: (task.slug if admin), at: task.updated_at,
               sub_label: sub_label, eta: eta)
    end
  end

  # What an owner reads (ClientPipeline's sanitizer): a task naming only this
  # app's repo, or none (a chat-opened or build task), keeps its scrubbed title;
  # one that also names another repo is shared platform work.
  def self.owner_title(task, app, scrubber)
    repos = Array(task.attributes["card_repositories"]).compact_blank
    return ClientPipeline::SHARED_TITLE unless repos.empty? || repos == [ app.slug ]

    scrubber.title(task.title).presence || ClientPipeline::SHARED_TITLE
  end

  def self.live_key(task_stage, release_stage)
    return :all_done if task_stage == "shipped"
    return "building" if BUILDING_TASK_STAGES.include?(task_stage)
    return nil unless task_stage == "assembled"

    DEPLOYING_RELEASE_STAGES.include?(release_stage) ? "deploying" : "releasing"
  end
  private_class_method :live_key, :stages_for, :items_for, :owner_title
end

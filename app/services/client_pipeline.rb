# One app's tasks by lane, for its owner (docs/agents/system/client-pipeline.md;
# plan: Phase 8 of .agents/epics/domain-agents.md). Read-only; the page is
# /applications/:slug/pipeline.
#
#   ClientPipeline.build(app, admin: false)  # => Pipeline(lanes:, lanes_status:, release:)
#
# THE SANITIZER. A non-admin's cards are built from an allow-list, never by
# stripping a full task: title (scrubbed), lane, time in lane, a neutral role
# ("Builder" while building, "Reviewer" in review), "On hold" for a block, and the
# queue position. Nothing else crosses: no slug, PR, agent or soul, mascot, cost or
# token count, reviewer note, session id, repo list, desk path or other app. The
# title is scrubbed too, because a title is free text an agent wrote: a URL or a
# filesystem path becomes "[link]", a credential mention turns the whole title
# into "Security maintenance", a soul's name becomes "the team", and another
# app's name becomes "a shared component". An admin's card adds the slug and the
# PR link; the title stays as written.
module ClientPipeline
  SHIPPED_WINDOW = 14.days

  # `age` phrases the card's time in the lane ("3 hours in review").
  Lane = Struct.new(:key, :stage, :label, :role, :age, keyword_init: true) do
    def age_line(time) = format(age, time: time)
  end
  LANES = [
    Lane.new(key: "queued",   stage: "designed",  label: "Queued",       age: "%{time} in the queue"),
    Lane.new(key: "building", stage: "building",  label: "Building",     age: "%{time} building", role: "Builder"),
    Lane.new(key: "review",   stage: "submitted", label: "In review",    age: "%{time} in review", role: "Reviewer"),
    Lane.new(key: "ready",    stage: "reviewed",  label: "Ready for QA", age: "%{time} ready"),
    Lane.new(key: "qa",       stage: "assembled", label: "On QA",        age: "%{time} on QA"),
    Lane.new(key: "shipped",  stage: "shipped",   label: "Shipped",      age: "shipped %{time} ago")
  ].freeze

  # The stamp a task's current lane started at (Task#set_stage_timestamp).
  ENTERED_AT = { "designed" => :created_at, "building" => :started_at, "submitted" => :submitted_at,
                 "reviewed" => :reviewed_at, "assembled" => :assembled_at, "shipped" => :completed_at }.freeze

  # Every key a non-admin card may carry. The sanitizer test pins it.
  OWNER_FIELDS = %i[title lane entered_at role on_hold queue_position].freeze
  ADMIN_FIELDS = (OWNER_FIELDS + %i[slug pr_url]).freeze

  Card = Struct.new(*ADMIN_FIELDS, keyword_init: true)
  LaneView = Struct.new(:lane, :cards, keyword_init: true) do
    def key = lane.key
    def label = lane.label
  end
  # The current release as the owner may see it: its state and how many of this
  # app's tasks ride it. No slug, branch or URL.
  ReleaseView = Struct.new(:state, :count, keyword_init: true) do
    def label = state == "assembled" ? "on QA, green and ready to ship" : "being assembled for QA"
  end
  Pipeline = Struct.new(:app, :lanes, :lanes_status, :release, keyword_init: true)

  module_function

  def build(app, admin: false, now: Time.current)
    tasks = Task.for_repository(app.slug).where(stage: LANES.map(&:stage)).ordered.to_a
    tasks.reject! { |task| task.stage == "shipped" && (task.completed_at.nil? || task.completed_at < now - SHIPPED_WINDOW) }
    by_stage = tasks.group_by(&:stage)
    scrubber = Scrubber.new(app)

    lanes = LANES.map do |lane|
      cards = Array(by_stage[lane.stage]).each_with_index.map do |task, index|
        card(task, lane, admin: admin, scrubber: scrubber, queue_position: (index + 1 if lane.stage == "designed"))
      end
      LaneView.new(lane: lane, cards: cards)
    end
    Pipeline.new(app: app, lanes: lanes, lanes_status: BuildingLanes.status(app), release: release_view(app))
  end

  def card(task, lane, admin:, scrubber:, queue_position: nil)
    fields = {
      title: admin ? task.title : scrubber.title(task.title),
      lane: lane.label,
      entered_at: task.public_send(ENTERED_AT.fetch(lane.stage)) || task.updated_at,
      role: lane.role,
      on_hold: task.stage == "building" && task.blocked_at.present?,
      queue_position: queue_position
    }
    fields.merge!(slug: task.slug, pr_url: task.pr_url.presence) if admin
    Card.new(**fields)
  end

  def release_view(app)
    release = Release.current
    return nil unless release

    ReleaseView.new(state: release.state, count: release.tasks.for_repository(app.slug).count)
  end

  # Scrubs a task title for a non-admin (see THE SANITIZER above).
  class Scrubber
    URL = %r{\b(?:https?|wss?|file)://\S+|\blocalhost(?::\d+)?\S*|\b127\.0\.0\.1(?::\d+)?\S*}i
    PATH = %r{(?:~|/Users|/home|/private|/tmp|/var)/\S+|\S*\.worktrees/\S*}
    CREDENTIAL = /credential|password|passphrase|secret|token|api[\s_-]?key|private[\s_-]?key|1password|\bop:\/\/|keypair|\bkeys?\b|\bsign(?:er|ers|ing)\b|seed phrase|\b[A-Z][A-Z0-9]*_(?:KEY|TOKEN|SECRET)\b/i
    CREDENTIAL_TITLE = "Security maintenance".freeze

    def initialize(app)
      @app = app
      @souls = word_pattern(soul_names - own_names)
      @apps = word_pattern(App.where.not(slug: app.slug).pluck(:name, :slug).flatten - own_names)
    end

    def title(text)
      text = text.to_s
      return CREDENTIAL_TITLE if text.match?(CREDENTIAL)

      text = text.gsub(URL, "[link]").gsub(PATH, "[link]")
      text = text.gsub(@apps, "a shared component") if @apps
      text = text.gsub(@souls, "the team") if @souls
      text.squish
    end

    private

    def own_names = [ @app.name, @app.slug ].compact_blank

    def soul_names
      souls = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls")
      (souls.flat_map { |soul| [ soul["name"], soul["slug"] ] } + Agent.pluck(:name, :slug).flatten + %w[Pokemon Pokémon]).compact_blank.uniq
    end

    def word_pattern(words)
      words = words.compact_blank.uniq.sort_by { |word| -word.length }
      return nil if words.empty?

      /(?<![\w-])(?:#{words.map { |word| Regexp.escape(word) }.join('|')})(?![\w-])/i
    end
  end
end

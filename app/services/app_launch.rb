# Build my app (docs/agents/system/client-cto.md; design:
# .agents/epics/build-with-xan-design.md step 4 and client-app-build-design.md
# build-order step 1, "Request -> App link").
#
#   AppLaunch.new(app_request, subdomain: "pawsome").call!   # => AppLaunch::Result
#
# In ONE transaction, from a request whose intake is complete:
#
#   1. the request claims the subdomain and moves to `queued` (an admin's is a
#      showcase build), exactly the guarantees AppRequest#queue! always gave
#   2. the App, slug = subdomain, its tier the request's, its theme_colors the
#      chosen palette (the one place the launch/template step reads the client's
#      colours from: bin/launch-app, docs/agents/system/new-app-onboarding-sop.md)
#   3. the requester's AppMembership, role owner
#   4. the AppCto: the name, portrait and palette chosen at intake, the plan and facts
#   5. the board task "Build Launch App <sub>", designed, repositories [<sub>],
#      so the tier's lane cap (BuildingLanes) governs its build
#   6. Xan's handover, the first turn of the owner's chat with the new CTO
#      (AgentMessages::ClientCtoHandover); the dispatcher answers it with the greeting
#
# Any failure rolls every row back: no App without its owner, CTO and task, and
# no task that outlives a failed claim. AFTER the commit, never inside it, two
# jobs: AppRequestDiscordJob (a Discord outage never undoes a claim) and
# AppIntakeMoveJob (R2 copies cannot be rolled back, so the files move only once
# the app certainly exists; AppIntakeMove is idempotent and re-runnable).
#
# An incomplete intake is refused before anything is written (Incomplete, which
# names what is missing in the checklist's words: Idea, CTO, Colors, Address,
# Account).
class AppLaunch
  class Incomplete < StandardError
    attr_reader :missing

    def initialize(missing)
      @missing = missing
      super("Finish these first: #{missing.join(', ')}.")
    end
  end

  # What Xan's intake gathered (the request's intake columns, owned by the
  # build-with-xan-intake task): the CTO's name and portrait key, the palette
  # ({ "name", "light", "dark" }) and the sharpened answers ({ "idea",
  # "title", "features" }, or a v1 draft's "audience" and "day_one").
  Intake = Struct.new(:cto_name, :cto_avatar, :palette, :answers, keyword_init: true) do
    def self.from(request)
      read = ->(attr) { request.respond_to?(attr) ? request.public_send(attr) : nil }
      new(cto_name: read.call(:cto_name), cto_avatar: read.call(:cto_avatar), palette: read.call(:palette),
          answers: read.call(:answers))
    end

    def answers_hash = answers.is_a?(Hash) ? answers.transform_keys(&:to_s) : {}
  end

  Result = Struct.new(:request, :app, :membership, :app_cto, :task, :handover, keyword_init: true)

  ANSWER_LIMIT = 500
  DEFAULT_EMOJI = "📱".freeze

  attr_reader :request, :intake

  def initialize(request, subdomain:, intake: Intake.from(request), now: Time.current)
    @request = request
    @subdomain = AppRequest.normalize_subdomain(subdomain).presence
    @intake = intake
    @now = now
  end

  # The checklist items still open, in the checklist's order; empty when the
  # request may launch. The subdomain's availability is the model's validation
  # (AppRequest#subdomain_is_claimable), reported as a RecordInvalid on save.
  def missing
    list = []
    list << "Idea" if intake.answers_hash["idea"].to_s.strip.blank?
    list << "CTO" if intake.cto_name.to_s.squish.blank? || intake.cto_name.to_s.squish.length > AppCto::NAME_LIMIT ||
                     intake.cto_avatar.blank?
    list << "Theme" unless AppPalette.valid?(intake.palette)
    list << "Domain" if @subdomain.nil?
    list << "Account" if request.user.nil?
    list
  end

  def complete? = missing.empty?

  def call!
    raise Incomplete, missing unless complete?

    result = AppRequest.transaction do
      claim!
      app = App.create!(slug: @subdomain, name: app_name, emoji: DEFAULT_EMOJI, color: palette.dig("light", "primary"),
                        description: request.prompt.to_s.lines.first.to_s.strip[0, 280], package_tier: request.tier,
                        status: "active", theme_colors: palette)
      membership = AppMembership.create!(app_slug: app.slug, user_slug: owner_slug, role: "owner")
      app_cto = AppCto.create!(app: app, name: intake.cto_name.to_s.squish, portrait: intake.cto_avatar.presence,
                               palette: palette, plan: plan, facts: facts, app_request_token: request.token)
      task = Task.create!(task_attributes)
      request.update!(task_slug: task.slug)
      handover = AgentMessages::ClientCtoHandover.enqueue!(app_cto: app_cto, user: request.user, now: @now)
      Result.new(request: request, app: app, membership: membership, app_cto: app_cto, task: task, handover: handover)
    end
    AppRequestDiscordJob.perform_later(request.id)
    AppIntakeMoveJob.perform_later(request.id)
    result
  end

  private

  def claim!
    request.subdomain = @subdomain
    request.status = "queued"
    request.queued_at = @now
    # An admin's request is a showcase build (an example of what the App
    # Builder delivers), never a customer's — kept apart everywhere it shows.
    request.showcase = true if request.user&.admin?
    request.save!
  end

  def palette = @palette ||= AppPalette.normalize(intake.palette)

  # The app's name: its address in words ("pawsome-grooming" reads "Pawsome Grooming").
  def app_name = @subdomain.tr("-", " ").titleize

  # The plan the CTO restates: the sharpened idea and its day-one goal.
  def plan
    answers = intake.answers_hash
    features = Array(answers["features"]).map { |f| f.to_s.strip }.compact_blank
    [ answers["idea"].to_s.strip, ("Key features: #{features.join('; ')}" if features.any?),
      ("Day one: #{answers['day_one'].to_s.strip}" if answers["day_one"].present?) ]
      .compact_blank.join("\n")[0, AppCto::PLAN_LIMIT]
  end

  # What the persona's APP PERSONA block lists besides the plan: the owner's
  # name, the original prompt, the palette's name, and each sharpened answer.
  def facts
    answers = intake.answers_hash.filter_map do |key, value|
      text = value.is_a?(String) ? value : value.to_json
      [ key.to_s[0, 40], text.strip[0, ANSWER_LIMIT] ] if text.present?
    end.to_h
    palette_name = intake.palette.is_a?(Hash) ? (intake.palette["name"] || intake.palette[:name]).to_s[0, 40].presence : nil
    { "owner" => request.user.display_name.to_s[0, 100], "prompt" => request.prompt.to_s[0, ANSWER_LIMIT],
      "palette_name" => palette_name }.compact.merge(answers)
  end

  # A user with no slug yet gets one on save (Sluggable), as AppMembership.seed_owners! does.
  def owner_slug
    request.user.save! if request.user.slug.blank?
    request.user.slug
  end

  def task_attributes
    showcase = request.showcase?
    {
      # Four words whatever the name: the board reads best with a 3-5 word title, and
      # a hyphenated subdomain stays one word.
      title: "Build Launch App #{@subdomain}",
      stage: "designed",
      priority: 1,
      description: "#{showcase ? 'Showcase' : "#{tier_name}-tier"} app requested through /build by #{request.user&.email || 'unknown'}.",
      metadata: { "devops" => {
        "kind" => "feature",
        "repositories" => [ @subdomain ],
        "acceptance" => [ "#{request.host} serves the app the requester described", request.footer_criterion ],
        "agent_context" => "Prompt from the requester, verbatim:\n\n#{request.prompt}\n\n#{request.intake_context}" \
                           "Subdomain reserved: #{request.host}. Tier: #{request.tier}. App request token: #{request.token}." \
                           "#{showcase ? ' SHOWCASE build: an example of what the App Builder delivers, submitted by an admin.' : ''}" \
                           "\n\nTheme colours (App#theme_colors, light and dark): #{palette.to_json}" \
                           "\n\n#{AppRequest::BUILDER_POINTER}"
      } }
    }
  end

  def tier_name = WorkspacePackage.find(request.tier)&.name || request.tier.to_s.capitalize
end

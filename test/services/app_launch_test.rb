require "test_helper"
require_relative "../support/client_cto_fixtures"

# [unit] AppLaunch (Build my app): from a complete intake, ONE transaction makes
# the App, its owner membership, its AppCto, the queued board task and Ray's
# handover; a failure anywhere leaves none of them; an incomplete intake is
# refused before anything is written; the Discord and intake-move jobs run only
# after the commit.
class AppLaunchTest < ActiveSupport::TestCase
  include ClientCtoFixtures
  include ActiveJob::TestHelper

  def draft(user: users(:viewer), **attrs) = AppRequest.create!({ prompt: "A booking site for my groomer", user: user }.merge(attrs))

  def launch(request = draft, subdomain: "pawsome", intake: client_intake)
    AppLaunch.new(request, subdomain: subdomain, intake: intake).call!
  end

  test "a complete intake makes the app, its owner, its CTO, the task and the handover together" do
    result = launch
    request = result.request.reload

    assert request.queued?
    assert_equal "pawsome", request.subdomain
    app = App.find_by!(slug: "pawsome")
    assert_equal [ "Pawsome", "vibe", "#4F46E5" ], [ app.name, app.package_tier, app.color ]
    assert_equal PALETTE, app.theme_colors, "the palette is the app's launch theme"
    assert AppMembership.owners.exists?(app_slug: "pawsome", user_slug: users(:viewer).slug)
    assert AppOwnership.manage_app?(users(:viewer), "pawsome")

    cto = app.client_cto
    assert_equal [ "Nova", "harbor", PALETTE, PLAN, request.token ],
                 [ cto.name, cto.portrait, cto.palette, cto.plan, cto.app_request_token ]
    assert_equal [ "Viewer User", "Dog owners in Denver", "Book a grooming slot" ],
                 cto.facts.values_at("owner", "audience", "day_one")

    task = Task.find_by!(slug: request.task_slug)
    assert_equal [ "Build Launch App pawsome", "designed" ], [ task.title, task.stage ]
    assert_equal [ "pawsome" ], task.devops_repositories, "the tier's lane cap governs the build"
    assert_includes task.description, "Vibe-tier", "named from the request's tier, not hardcoded"
    assert_includes task.metadata.dig("devops", "agent_context"), "#4F46E5"
    assert task.metadata.dig("devops", "agent_context").end_with?(AppRequest::BUILDER_POINTER)

    handover = result.handover
    assert_equal [ "web", "pawsome", "web:pawsome:#{users(:viewer).id}", "client_cto", "completed", "Ray" ],
                 [ handover.channel, handover.channel_ref, handover.thread_key, handover.soul_slug, handover.status, handover.author_name ]
    assert_equal "Meet Nova, your CTO. I'll hand you over.", handover.content
  end

  test "[unit] the launch sets the app's initial load, so the owner's first visit plays the launch animation" do
    assert launch.app_cto.reload.launch_animation_pending?
  end

  test "[unit] the greeting names the owner's first name, else their name's first word, else there" do
    user = users(:viewer)
    cto = launch.app_cto
    user.update_columns(first_name: "Jordan", name: "Viewer User")
    assert AgentMessages::ClientCtoHandover.greeting(cto, user).start_with?("Hi Jordan, I'm Nova")
    user.update_columns(first_name: nil)
    assert AgentMessages::ClientCtoHandover.greeting(cto, user).start_with?("Hi Viewer, I'm Nova")
    user.update_columns(name: nil)
    assert AgentMessages::ClientCtoHandover.greeting(cto, user).start_with?("Hi there, I'm Nova"), "never the email's local part"
  end

  test "[unit] only a nameless owner's greeting ends with the first-name ask" do
    user = users(:viewer)
    cto = launch.app_cto
    ask = AgentMessages::FirstNameAsk::QUESTION
    user.update_columns(first_name: nil, name: nil)
    assert AgentMessages::ClientCtoHandover.greeting(cto, user).end_with?("\n\n#{ask}")
    user.update_columns(name: "Viewer User")
    assert_not_includes AgentMessages::ClientCtoHandover.greeting(cto, user), ask, "a name's first word is enough to greet by"
  end

  test "the handover carries the CTO's code-written greeting, so no model runs; the owner's own next words are answered as the app's owner" do
    launched = launch
    handover = launched.handover

    assert_empty AgentMessage.claimable(soul: "client_cto").to_a, "already answered: the dispatcher never claims it"
    assert_equal "app-launch", handover.hold_released_by
    assert_equal %w[received routed hold_released completed reply_posted], handover.events.order(:id).pluck(:kind)
    assert_equal [ "posted", "code greeting" ], [ handover.reply_status, handover.action_summary ]
    greeting = handover.response_text
    # First person and by name, in line (never "building now": nobody builds a
    # designed task, task app-card-stage-labels), what the card shows, what to
    # do meanwhile (task build-launch-handoff): code wrote it from the launch's own rows.
    assert greeting.start_with?("Hi Viewer, I'm Nova, the agent who'll be managing Pawsome."), greeting
    assert_includes greeting, "It's in line to be built: your brand sheet, the first version of the app, and its home at **pawsome.mcritchie.studio**."
    assert_includes greeting, "The card above shows live progress: Prepping until a builder starts, then Building, Reviewing, " \
                              "Releasing to a preview link for you, and Deploying once you approve."
    assert greeting.end_with?("Meanwhile, tell me anything you'd like added or changed, or ask about the plan.")
    assert_equal "designed", launched.task.reload.stage, "the greeting's claim matches the task: in line, not building"
    assert_no_match(/building now|it builds/i, greeting)
    assert_operator greeting.split.size, :<=, 70, "short: Alex's voice, plain and warm"

    follow_up = AgentMessages::WebIngest.new(user: users(:viewer), cto: AppOwnership.cto_for_app("pawsome"))
                                        .call("Can it take payments?", client_id: "client-0001")
    assert_equal "received", follow_up.status, "the app-owner rule answers the owner on their own app's chat"
    assert_nil follow_up.hold_released_at, "answered by the rule, not by a release"
    assert_equal "client", follow_up.usage_audience
    assert_equal "public", follow_up.person.role, "their role is unchanged, so Discord and email still hold them"
  end

  test "a failure anywhere in the launch leaves no app, owner, CTO, task, handover or claim" do
    request = draft
    counts = -> { [ App.count, AppMembership.count, AppCto.count, Task.count, AgentMessage.count ] }
    before = counts.call

    Task.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid, Task.new }) do
      assert_raises(ActiveRecord::RecordInvalid) { launch(request) }
    end

    assert_equal before, counts.call
    assert request.reload.draft?
    assert_nil request.subdomain
    assert_enqueued_jobs 0
  end

  test "a name an app or another request already holds is refused with nothing written" do
    launch
    assert_no_difference [ -> { App.count }, -> { AppCto.count }, -> { Task.count } ] do
      error = assert_raises(ActiveRecord::RecordInvalid) { launch(draft(user: users(:alex)), subdomain: "pawsome") }
      assert_match(/taken/, error.message)
    end
    assert_equal "That name is taken.", AppRequest.unavailable_reason("pawsome")
  end

  test "an incomplete intake is refused before anything is written, naming the checklist items" do
    cases = {
      [ "CTO" ] => client_intake(cto_name: "  "),
      [ "Idea" ] => client_intake(answers: { "audience" => "Dog owners" }),
      [ "Idea", "CTO" ] => client_intake(cto_avatar: nil, answers: nil),
      [ "Theme" ] => client_intake(palette: { "light" => PALETTE["light"] }),
      [ "CTO", "Theme" ] => client_intake(cto_name: nil, palette: nil)
    }
    cases.each do |missing, intake|
      assert_no_difference [ -> { App.count }, -> { Task.count }, -> { AgentMessage.count } ] do
        error = assert_raises(AppLaunch::Incomplete) { launch(draft, intake: intake) }
        assert_equal missing, error.missing
      end
    end

    assert_equal [ "Domain" ], AppLaunch.new(draft, subdomain: "!!", intake: client_intake).missing
    assert_equal [ "Account" ], AppLaunch.new(AppRequest.create!(prompt: "x"), subdomain: "pawsome", intake: client_intake).missing
    assert_equal 0, AppRequest.where(status: "queued").count
  end

  test "the Discord announcement and the intake move run after the commit" do
    launch
    request = AppRequest.find_by!(subdomain: "pawsome")
    assert_enqueued_with(job: AppRequestDiscordJob, args: [ request.id ])
    assert_enqueued_with(job: AppIntakeMoveJob, args: [ request.id ])
  end

  test "the app is named from the idea card's confirmed title, squished and capped, and from its address without one" do
    titled = launch(draft, subdomain: "league-hub",
                           intake: client_intake(answers: ANSWERS.merge("title" => "  League   Standings Hub ")))
    assert_equal "League Standings Hub", titled.app.name, "the title, not the address in words"
    assert titled.handover.response_text.start_with?("Hi Viewer, I'm Nova, the agent who'll be managing League Standings Hub."), "the greeting names it too"

    # An admin's showcase apps are not held to the one-app plan, so one user launches the other two.
    long = launch(draft(user: users(:alex)), subdomain: "long-one", intake: client_intake(answers: ANSWERS.merge("title" => "Word " * 20)))
    assert_operator long.app.name.length, :<=, AppLaunch::NAME_LIMIT
    refute long.app.name.end_with?(" ")

    blank = launch(draft(user: users(:alex)), subdomain: "pawsome-grooming", intake: client_intake(answers: ANSWERS.merge("title" => "   ")))
    assert_equal "Pawsome Grooming", blank.app.name, "no title: the address in words"
  end

  test "an admin's launch is a showcase build" do
    result = launch(draft(user: users(:alex)), subdomain: "coin-toss")
    assert result.request.showcase?
    assert_includes result.task.description, "Showcase"
  end

  test "the plan is the sharpened idea and its day-one goal; the palette's name is a fact" do
    result = launch(draft, intake: client_intake(answers: { "idea" => "Slots first." },
                                                 palette: PALETTE.merge("name" => "Harbor dusk")))
    assert_equal "Pawsome", result.app.name
    assert_equal "Slots first.", result.app_cto.plan
    assert_equal "Harbor dusk", result.app_cto.facts["palette_name"]
    assert_equal PALETTE, result.app.theme_colors, "only the colours are the theme"
  end

  test "Intake.from reads the request's intake columns" do
    row = Struct.new(:cto_name, :cto_avatar, :palette, :answers).new("Nova", "harbor", PALETTE, { "idea" => "x" })
    intake = AppLaunch::Intake.from(row)
    assert_equal [ "Nova", "harbor", PALETTE, { "idea" => "x" } ], intake.to_a
    assert_equal({}, AppLaunch::Intake.new(answers: "not a hash").answers_hash)
  end
end

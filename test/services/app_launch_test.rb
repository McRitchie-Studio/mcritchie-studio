require "test_helper"
require_relative "../support/client_cto_fixtures"

# [unit] AppLaunch (Build my app): from a complete intake, ONE transaction makes
# the App, its owner membership, its AppCto, the queued board task and Xan's
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
    assert_equal [ "web", "pawsome", "web:pawsome:#{users(:viewer).id}", "client_cto", "received", "Ray" ],
                 [ handover.channel, handover.channel_ref, handover.thread_key, handover.soul_slug, handover.status, handover.author_name ]
    assert_equal "Meet Nova, your CTO. I'll hand you over.", handover.content
  end

  test "the handover is claimable although the client's role is not answered; their own next words are answered as the app's owner" do
    handover = launch.handover

    assert_equal [ handover ], AgentMessage.claimable(soul: "client_cto").to_a
    assert_equal "app-launch", handover.hold_released_by
    assert_equal %w[received routed hold_released], handover.events.order(:id).pluck(:kind)

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
      [ "Colors" ] => client_intake(palette: { "light" => PALETTE["light"] }),
      [ "CTO", "Colors" ] => client_intake(cto_name: nil, palette: nil)
    }
    cases.each do |missing, intake|
      assert_no_difference [ -> { App.count }, -> { Task.count }, -> { AgentMessage.count } ] do
        error = assert_raises(AppLaunch::Incomplete) { launch(draft, intake: intake) }
        assert_equal missing, error.missing
      end
    end

    assert_equal [ "Address" ], AppLaunch.new(draft, subdomain: "!!", intake: client_intake).missing
    assert_equal [ "Account" ], AppLaunch.new(AppRequest.create!(prompt: "x"), subdomain: "pawsome", intake: client_intake).missing
    assert_equal 0, AppRequest.where(status: "queued").count
  end

  test "the Discord announcement and the intake move run after the commit" do
    launch
    request = AppRequest.find_by!(subdomain: "pawsome")
    assert_enqueued_with(job: AppRequestDiscordJob, args: [ request.id ])
    assert_enqueued_with(job: AppIntakeMoveJob, args: [ request.id ])
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

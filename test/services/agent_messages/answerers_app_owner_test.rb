require "test_helper"
require_relative "../../support/client_cto_fixtures"

# [unit] The app-owner exception (config/agent_answerers.yml `app_owners`;
# AgentMessages::Answerers#app_owner_thread?), with the shipped config: an app's
# CTO answers a person whose hub user owns that app, on that app's web CTO thread
# only; the claim's SQL guard is the same rule; everywhere else the same person
# stays held; they speak as the app's client; and the owner meter caps them at
# ingest with a line from code.
class AnswerersAppOwnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ClientCtoFixtures

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    @answerers = AgentMessages::Answerers.current
    @alex = AgentPerson.seed_owner!
    @turf = apps(:turf_monster)
    @user = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: @turf, user: @user)
    @person = AgentMessages::WebIngest.person_for(@user)
  end

  teardown { AgentMessages::Answerers.reset! }

  def row(app: "turf-monster", soul: "turf_monster", channel: "web", person: @person, user_id: @user.id,
          thread_key: nil, status: "received")
    AgentMessage.create!(channel: channel, external_id: SecureRandom.uuid, channel_ref: app,
                         thread_key: thread_key || AgentMessages::WebChat.thread_key(app, user_id),
                         soul_slug: soul, content: "hi", person: person, status: status, author_ref: user_id.to_s)
  end

  def ingest(user, text, app: "turf-monster")
    AgentMessages::WebIngest.new(user: user, cto: AppOwnership.cto_for_app(app)).call(text)
  end

  def claimable_ids(soul) = AgentMessage.claimable(soul: soul).pluck(:id)

  test "the shipped config turns the rule on with a default monthly cap" do
    assert_equal %w[owner], @answerers.roles, "the roles list is unchanged"
    assert_equal 1_000_000, @answerers.app_owners.default_monthly_tokens
  end

  test "an owner is answered on their own app's CTO thread, and the claim guard agrees" do
    own = row

    assert @answerers.app_owner_thread?(own)
    assert @answerers.allowed?(@person, message: own)
    assert_equal [ own.id ], claimable_ids("turf_monster")
  end

  test "the same person is refused on every other thread, channel and app, in Ruby and in SQL" do
    other = User.create!(email: "other@turf.example", name: "Other", role: "viewer")
    cases = {
      "no message (Discord and email ask without one)" => nil,
      "another app's CTO thread" => row(app: "mcritchie-studio", soul: "avi"),
      "their app's thread, the wrong soul" => row(soul: "avi"),
      "their app's key on Discord" => row(channel: "discord"),
      "their app's key by email" => row(channel: "email"),
      "another user's thread on their app" => row(user_id: other.id)
    }
    cases.each do |label, message|
      refute @answerers.allowed?(@person, message: message), "#{label} must be held"
    end
    assert_empty claimable_ids(%w[turf_monster avi]), "the SQL guard holds every one of them"
    refute @answerers.app_owner_thread?(row(app: "build", soul: "xan", thread_key: "web:build:tok123")),
           "a /build thread is public intake's, never the owner rule's"
  end

  test "a person whose user owns nothing, or who has no user, is held on that app's thread" do
    stranger = User.create!(email: "stranger@turf.example", name: "Stranger", role: "viewer")
    unowned = AgentMessages::WebIngest.person_for(stranger)
    no_user = AgentPerson.create!(display_name: "Loose")

    refute @answerers.allowed?(unowned, message: row(person: unowned, user_id: stranger.id))
    refute @answerers.allowed?(no_user, message: row(person: no_user))
    assert_empty claimable_ids("turf_monster")
  end

  test "membership is read now: an owner removed from the app is held again" do
    own = row
    AppMembership.where(user_slug: @user.slug).delete_all

    refute @answerers.allowed?(@person, message: own)
    assert_empty claimable_ids("turf_monster")
  end

  test "a client app's CTO answers its owner on that app only" do
    pawsome = client_app!
    AppMembership.create!(app: pawsome, user: @user)
    own = row(app: "pawsome", soul: "client_cto")
    stranger_app = client_app!(slug: "barkly", name: "Barkly")
    foreign = row(app: stranger_app.slug, soul: "client_cto")

    assert @answerers.allowed?(@person, message: own)
    refute @answerers.allowed?(@person, message: foreign)
    assert_equal [ own.id ], claimable_ids("client_cto")
  end

  test "the owner speaks as the app's client: no owner or team action, and their go is refused" do
    own = ingest(@user, "What should we build next?")
    audience = AgentMessages::MemoryBundle.new(own).audience
    assert_equal({ "role" => "client", "client_domain" => "turf_monster" }, audience)

    rights = AgentMailbox::Audience.new(role: audience["role"], client_domain: audience["client_domain"])
    refute rights.may?(:read_action)
    refute rights.may?(:internal_context)
    refute rights.may?(:propose_operate)
    refute rights.may?(:confirm_proposal)

    own.update_columns(status: "completed", completed_at: Time.current)
    AgentProposal.create!(thread_key: own.thread_key, channel: "web", channel_ref: "turf-monster", soul_slug: "turf_monster",
                          person: @person, source_message: own, kind: "ask", capability: "x", params: {},
                          summary: "x", expires_at: 1.day.from_now)
    go = ingest(@user, "go")
    assert_equal "held", go.status
    assert_includes go.events.pluck(:kind), "confirm_refused"
  end

  test "a team-role owner keeps the team audience on an app they own; the rule never applies to them" do
    @person.set_role!("team")
    team_row = row

    refute @answerers.app_owner_thread?(team_row), "owner and team are answered by their role"
    assert @answerers.allowed?(@person, message: team_row) == @answerers.roles.include?("team")
    assert_equal "team", AgentMessages::MemoryBundle.new(team_row).audience["role"]
  end

  test "at the owner meter's cap the message is answered in code with the cap line and never claimed" do
    AgentMessages::Answerers.current = AgentMessages::Answerers.new(
      [ "owner" ], app_owners: { "default_monthly_tokens" => 500 }
    )
    spent = row(status: "completed")
    spent.update_columns(completed_at: 1.minute.ago, run_meta: { "input_tokens" => 500, "audience" => "client" })

    message = nil
    assert_enqueued_with(job: AgentMessageReplyJob) { message = ingest(@user, "one more?") }

    assert_equal "completed", message.status
    assert_match(/used its monthly agent allowance/, message.response_text)
    assert_equal "usage cap", message.action_summary
    assert_includes message.events.pluck(:kind), "usage_capped"
    assert_empty claimable_ids("turf_monster")
  end

  test "under the cap the owner is received, and an admin's lift removes the cap" do
    AgentMessages::Answerers.current = AgentMessages::Answerers.new(
      [ "owner" ], app_owners: { "default_monthly_tokens" => 500 }
    )
    spent = row(status: "completed")
    spent.update_columns(completed_at: 1.minute.ago, run_meta: { "input_tokens" => 499, "audience" => "client" })
    assert_equal "received", ingest(@user, "under").status

    spent.update_columns(run_meta: { "input_tokens" => 10_000, "audience" => "client" })
    @turf.update!(cto_cap_lifted_at: Time.current)
    AgentMessage.where(status: "received").update_all(status: "completed")
    assert_equal "received", ingest(@user, "lifted").status
  end

  test "a tier's own allowance wins over the default" do
    @turf.update!(package_tier: "builder")
    packages = [ WorkspacePackage.new({ "key" => "builder", "name" => "Builder", "price_monthly" => 100, "cto_monthly_tokens" => 5_000 }) ]
    WorkspacePackage.stub(:all, packages) do
      WorkspacePackage.stub(:find, ->(key) { packages.find { |p| p.key == key } }) do
        assert_equal 5_000, AgentUsage.owner_meter(@turf).allowance
      end
    end
  end

  test "the config refuses a malformed app_owners block" do
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new([ "owner" ], app_owners: { "default_monthly_tokens" => 0 }) }
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new([ "owner" ], app_owners: "yes") }
    assert_nil AgentMessages::Answerers.new([ "owner" ]).app_owners
  end
end

require "test_helper"
require "support/google_connect_fakes"
require_relative "../../support/client_cto_fixtures"
require_relative "../../support/agent_message_fixtures"

module AgentMessages
  # [unit] The bundle's GOOGLE layer (AgentMessages::MemoryBundle#google_reader):
  # `google_context` only for the owner of what the soul answers for, read from
  # that owner's own connections. A client CTO's app owner on their own app's
  # thread gets THEIR snapshot; an admin owner on a hub soul gets the
  # household's. Everyone else (a public visitor on the same app, another app's
  # owner, a client, the team, a /build thread) gets none, even when they have
  # connected Google themselves. The negative cases come first. Google is a
  # stand-in throughout.
  class MemoryBundleGoogleTest < ActiveSupport::TestCase
    include ClientCtoFixtures
    include AgentMessageFixtures
    include GoogleConnectFakes

    ALL = "openid email #{CALENDAR} #{GMAIL} #{DRIVE}".freeze

    setup do
      Answerers.current = Answerers.load
      @app = client_app!(slug: "pawsome", name: "Pawsome")
      @owner = User.create!(email: "pat@pawsome.example", name: "Pat Owner", role: "viewer")
      AppMembership.create!(app: @app, user: @owner)
      @owner_person = WebIngest.person_for(@owner)
      @originals = ENV.to_h.slice(*CREDS.keys)
      CREDS.each { |k, v| ENV[k] = v }
      google_answers(200, { access_token: "ya29.SECRET-ACCESS" })
      google_reads(GoogleConnect::CalendarReader::EVENTS_URL => [ 200, { items: [
        { id: "e1", summary: "Groomer supplier call", start: { dateTime: "2026-10-28T15:00:00Z" }, end: { dateTime: "2026-10-28T16:00:00Z" } }
      ] } ])
    end

    teardown do
      Answerers.reset!
      reset_google_connect
      CREDS.each_key { |k| @originals.key?(k) ? ENV[k] = @originals[k] : ENV.delete(k) }
    end

    def connect!(user, email:, scope: SCOPE, refresh_token: "1//#{user.id}-refresh")
      store_google(email:, scope:, user:, refresh_token:)
    end

    def cto_row(user:, person: WebIngest.person_for(user), app: "pawsome", soul: "client_cto", thread_key: nil, channel: "web")
      AgentMessage.create!(channel: channel, external_id: SecureRandom.uuid, channel_ref: app,
                           thread_key: thread_key || WebChat.thread_key(app, user.id), soul_slug: soul,
                           content: "what's on my calendar?", person: person, status: "received", author_ref: user.id.to_s)
    end

    def google(message) = MemoryBundle.new(message).bundle["google_context"]

    # --- who gets NOTHING ------------------------------------------------------

    test "a public visitor on the same app gets no google_context, even with their own Google connected" do
      visitor = User.create!(email: "visitor@example.com", name: "Visitor", role: "viewer")
      connect!(visitor, email: "visitor@example.com", scope: ALL)
      connect!(@owner, email: "pat@example.com")

      message = cto_row(user: visitor)

      assert_equal "public", MemoryBundle.new(message).audience["role"]
      assert_nil google(message)
      assert_empty read_requests, "nothing is read for them"
      assert_empty google_requests
    end

    test "a visitor posting on the owner's thread key is not the owner and gets nothing" do
      visitor = User.create!(email: "visitor@example.com", name: "Visitor", role: "viewer")
      connect!(visitor, email: "visitor@example.com")
      connect!(@owner, email: "pat@example.com")

      assert_nil google(cto_row(user: visitor, thread_key: WebChat.thread_key("pawsome", @owner.id)))
      assert_empty read_requests
    end

    test "another app's owner gets nothing on this app, and this app's owner gets nothing on theirs" do
      barkly = client_app!(slug: "barkly", name: "Barkly")
      other = User.create!(email: "sam@barkly.example", name: "Sam", role: "viewer")
      AppMembership.create!(app: barkly, user: other)
      connect!(other, email: "sam@example.com", scope: ALL)
      connect!(@owner, email: "pat@example.com")

      assert_nil google(cto_row(user: other, app: "pawsome")), "Barkly's owner on Pawsome's CTO"
      assert_nil google(cto_row(user: @owner, app: "barkly")), "Pawsome's owner on Barkly's CTO"
      assert_empty read_requests
    end

    test "a client audience gets nothing, on a hub soul or on the CTO" do
      connect!(@owner, email: "pat@example.com")
      client = AgentPerson.create!(display_name: "Client", user: User.create!(email: "c@example.com", name: "C", role: "viewer"))
      client.set_role!("client", client_domain: "turf_monster")
      connect!(client.user, email: "client@example.com")

      hub = agent_message!(soul: "alex", author_ref: "client-1", person: client)
      assert_equal "client", MemoryBundle.new(hub).audience["role"]
      assert_nil google(hub)
      assert_nil google(cto_row(user: client.user, person: client))
      assert_empty read_requests
    end

    test "the team gets nothing, even an admin hub user whose person is team" do
      admin = User.create!(email: "ops@example.com", name: "Ops", role: "admin")
      team = AgentPerson.create!(display_name: "Ops", user: admin)
      team.set_role!("team")
      connect!(admin, email: "ops@example.com")

      assert_nil google(agent_message!(soul: "alex", author_ref: "team-1", person: team))
      assert_empty read_requests
    end

    test "an owner-role person whose hub user is not an admin, or who has no hub user, gets nothing on a hub soul" do
      connect!(@owner, email: "pat@example.com")
      @owner_person.set_role!("owner")
      loose = AgentPerson.create!(display_name: "Loose")
      loose.set_role!("owner")

      assert_nil google(agent_message!(soul: "alex", author_ref: "x", person: @owner_person))
      assert_nil google(agent_message!(soul: "alex", author_ref: "y", person: loose))
      assert_empty read_requests
    end

    test "the app owner on their own app's thread with another soul, on Discord, or on a /build thread gets nothing" do
      connect!(@owner, email: "pat@example.com")

      assert_nil google(cto_row(user: @owner, soul: "avi")), "not the app's CTO"
      assert_nil google(cto_row(user: @owner, channel: "discord")), "not the web chat"
      assert_nil google(cto_row(user: @owner, app: BuildIntake::CHANNEL_REF, soul: "alex",
                                thread_key: BuildIntake.thread_key("tok123"))), "a /build thread is public"
      assert_empty read_requests
    end

    test "the admin owner on a client app's CTO chat is not that app's owner and gets nothing" do
      alex = AgentPerson.seed_owner!
      connect!(users(:alex), email: "alex@mcritchie.studio")

      assert_nil google(cto_row(user: users(:alex), person: alex))
      assert_empty read_requests
    end

    test "an error while deciding or reading is no google_context, never a failed bundle" do
      connect!(@owner, email: "pat@example.com")
      GoogleConnect::OwnerContext.stub(:for_user, ->(*) { raise "boom" }) do
        bundle = MemoryBundle.new(cto_row(user: @owner)).bundle
        assert bundle.key?("google_context")
        assert_nil bundle["google_context"]
      end
    end

    # --- who gets their OWN ----------------------------------------------------

    test "the app owner on their own app's CTO thread gets their own snapshot, never another user's" do
      visitor = User.create!(email: "visitor@example.com", name: "Visitor", role: "viewer")
      connect!(visitor, email: "visitor@example.com", scope: ALL, refresh_token: "1//visitor-refresh")
      connect!(@owner, email: "pat@example.com", refresh_token: "1//owner-refresh")

      message = cto_row(user: @owner)
      context = google(message)

      assert_equal({ "role" => "client", "client_domain" => "pawsome" }, MemoryBundle.new(message).audience)
      assert_equal 1, context["accounts"], "the owner's one account, not the visitor's"
      assert_equal [ "Groomer supplier call" ], context["calendar"]["events"].map { _1["title"] }
      refute context.key?("gmail"), "the visitor's Gmail grant is not the owner's"
      assert_equal [ "1//owner-refresh" ], google_requests.map { _1[:form][:refresh_token] || _1[:form]["refresh_token"] }.uniq
      refute_match(/SECRET|refresh|ya29/, context.to_json)
    end

    test "an admin owner on a hub soul gets the household snapshot" do
      alex = AgentPerson.seed_owner!
      connect!(users(:alex), email: "alex@mcritchie.studio")
      connect!(@owner, email: "pat@example.com", scope: ALL)

      context = google(agent_message!(soul: "alex", author_ref: "500", person: alex))

      assert_equal 1, context["accounts"], "the admin's row only, never the app owner's"
      assert_equal [ "Groomer supplier call" ], context["calendar"]["events"].map { _1["title"] }
      refute context.key?("gmail")
    end
  end
end

require "test_helper"
require_relative "../support/agent_message_fixtures"
require_relative "../support/client_cto_fixtures"

# [unit] The client CTO on the board: a client app's CTO is its AppCto row worn
# by the one client_cto soul (AppOwnership), named by that row in the chat
# (WebChat), given that row as its persona and only that app's memory
# (MemoryBundle), heard as the app's client when its owner writes, and metered
# on that app alone (AgentUsage). Avi, Turf and Tyrion are unchanged.
class ClientCtoRoutingTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ClientCtoFixtures

  NOW = Time.zone.parse("2026-10-16 12:00 MDT")

  setup do
    @pawsome = client_app!
    @second = client_app!(slug: "fit-log", name: "Fit Log", cto_name: "Juno")
    @owner = User.create!(email: "pat@example.com", name: "Pat", role: "viewer")
    AppMembership.create!(app: @pawsome, user: @owner)
    @person = AgentMessages::WebIngest.person_for(@owner)
  end

  def web_message!(app_slug, content: "hello", status: "received", person: @person, **attrs)
    agent_message!(soul: "client_cto", channel: "web", guild_id: nil, channel_ref: app_slug,
                   thread_key: AgentMessages::WebChat.thread_key(app_slug, @owner.id), author_ref: @owner.id.to_s,
                   person: person, content: content, status: status, routed_by: "chat", **attrs)
  end

  test "a client app's CTO is its AppCto row on the client_cto soul; our own CTOs are unchanged" do
    cto = AppOwnership.cto_for_app("pawsome")
    assert_equal [ "client_cto", "pawsome", "Nova", nil ], [ cto.soul, cto.app_slug, cto.display_name, cto.domain ]
    assert cto.client?
    refute cto.settings?, "a client CTO has no report settings page"
    assert_equal "Juno", AppOwnership.cto_for_app("fit-log").display_name, "the row picks the voice"
    assert AgentMessages::WebIngest.available?(cto), "client_cto is listed for the web chat"

    { "turf-monster" => "turf_monster", "cyvasse" => "tyrion", "mcritchie-studio" => "avi" }.each do |app, soul|
      ours = AppOwnership.cto_for_app(app)
      assert_equal soul, ours.soul
      refute ours.client?
      assert ours.settings?
    end
    refute_includes AppOwnership.ctos.map(&:soul), "client_cto", "the configured list stays ours"
    assert_nil AppOwnership.cto_for_app("no-such-app")
  end

  test "a preloaded list resolves client CTOs without a query per app" do
    rows = AppCto.for_apps(%w[pawsome fit-log])
    ctos = AppOwnership.ctos
    queries = 0
    counter = ->(*) { queries += 1 }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      %w[pawsome fit-log].each { |slug| AppOwnership.cto_for_app(slug, ctos: ctos, client_ctos: rows) }
    end
    assert_equal 0, queries
  end

  test "the chat names a client CTO's turns by its app's row" do
    assert_equal "Nova", AgentMessages::WebChat.cto_name(web_message!("pawsome"))
    assert_equal "Juno", AgentMessages::WebChat.cto_name(web_message!("fit-log"))
    assert_equal "Turf", AgentMessages::WebChat.cto_name(agent_message!(soul: "turf_monster"))
  end

  test "the bundle carries this app's persona and only this app's memory, and an owner is the app's client" do
    web_message!("pawsome", content: "pawsome turn", status: "completed", response_text: "ok")
    web_message!("fit-log", content: "fit-log turn", status: "completed", response_text: "ok",
                            thread_key: "web:fit-log:#{@owner.id}")
    current = web_message!("pawsome", content: "what next?")

    bundle = AgentMessages::MemoryBundle.new(current).bundle
    assert_equal "Nova", bundle.dig("persona", "name")
    assert_equal PALETTE, bundle.dig("persona", "palette")
    turns = bundle.dig("person", "turns").map { |t| t["content"] } + bundle.dig("thread", "turns").map { |t| t["content"] }
    assert_includes turns, "pawsome turn"
    refute_includes turns, "fit-log turn", "one client app's CTO never recalls another's chat"
    assert_equal({ "role" => "client", "client_domain" => "pawsome" }, bundle["audience"])

    stranger = AgentPerson.create!(display_name: "Stranger")
    assert_equal "public", AgentMessages::MemoryBundle.new(web_message!("fit-log", person: stranger)).bundle.dig("audience", "role"),
                 "not the app's owner: still the public"
    avi = AgentMessages::MemoryBundle.new(agent_message!(soul: "avi", person: @person)).bundle
    assert_nil avi["persona"]
    assert_equal "public", avi.dig("audience", "role"), "only the client CTO scopes an owner as a client"
  end

  test "a client app is metered on its own client_cto answers, never another app's" do
    answered = lambda do |app_slug, tokens|
      message = web_message!(app_slug, status: "completed", completed_at: NOW - 1.day)
      message.update_columns(run_meta: { "input_tokens" => tokens, "output_tokens" => 0, "cache_read_tokens" => 0,
                                         "cache_creation_tokens" => 0, "audience" => "client" })
    end
    answered.call("pawsome", 70)
    answered.call("fit-log", 500)

    packages = [ WorkspacePackage.new({ "key" => "vibe", "name" => "Vibe", "price_monthly" => 0, "cto_monthly_tokens" => 100 }) ]
    WorkspacePackage.stub(:all, packages) do
      meter = AgentUsage.meter(@pawsome, now: NOW)
      assert_equal [ 70, 100 ], [ meter.used, meter.allowance ]
      assert_equal 500, AgentUsage.meter(@second, now: NOW).used

      assert_equal :ok, AgentUsage.gate(web_message!("pawsome"), now: NOW).state
      assert_equal :stop, AgentUsage.gate(web_message!("fit-log"), now: NOW).state
    end
  end
end

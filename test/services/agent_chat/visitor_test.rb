require "test_helper"

# [unit] Who a satellite says is chatting, as the hub decides it
# (AgentChat::Visitor), the per-(person, soul) thread key, and the allow-list
# (config/agent_routes.yml `web: apps:`).
class AgentChatVisitorTest < ActiveSupport::TestCase
  ANON = "anon-cookie-token-0001".freeze

  test "a signed-in email that is a hub user chats on chat:<soul>:<user id>, as their web person" do
    user = User.create!(email: "Builder@Example.com", name: "Builder", role: "viewer")
    visitor = AgentChat::Visitor.new("alex", email: " builder@example.COM ")

    assert visitor.signed_in?
    assert_equal user, visitor.user
    assert_equal "chat:alex:#{user.id}", visitor.thread_key
    assert_equal AgentMessages::WebIngest.person_for(user), visitor.person!
    assert_equal user.id.to_s, visitor.author_ref
  end

  test "the thread is one per (person, soul): another soul is another thread, an app is never in the key" do
    user = User.create!(email: "two@example.com", name: "Two", role: "viewer")

    assert_equal "chat:alex:#{user.id}", AgentChat::Visitor.new("alex", email: user.email).thread_key
    assert_equal "chat:avi:#{user.id}", AgentChat::Visitor.new("avi", email: user.email).thread_key
  end

  test "an email with no hub user gets its own public person and a person-keyed thread" do
    visitor = AgentChat::Visitor.new("alex", email: "stranger@example.com")
    assert_nil visitor.thread_key, "no thread before the first message"

    person = visitor.person!
    assert_equal "public", person.role
    assert AgentPersonIdentity.exists?(platform: "email", external_id: "stranger@example.com", agent_person_id: person.id)
    assert_equal "chat:alex:person:#{person.id}", visitor.thread_key!
    assert_equal person, AgentChat::Visitor.new("alex", email: "STRANGER@example.com").person!, "found again, never twice"
  end

  test "an email with no hub user that already wrote to team@ is that same person" do
    person = AgentPerson.resolve!(platform: "email", external_id: "known@example.com", display_name: "Known")

    visitor = AgentChat::Visitor.new("alex", email: "Known@example.com")
    assert_equal person, visitor.person!
    assert_equal "chat:alex:person:#{person.id}", visitor.thread_key
  end

  test "an anon token is a public visitor on a digest-keyed thread that never carries the token" do
    visitor = AgentChat::Visitor.new("alex", anon_token: ANON)

    refute visitor.signed_in?
    digest = AgentChat.anon_digest(ANON)
    assert_equal 32, digest.length
    assert_equal "chat:alex:anon:#{digest}", visitor.thread_key
    refute_includes visitor.thread_key, ANON
    assert_equal "public", visitor.person!.role
    assert AgentPersonIdentity.exists?(platform: "web", external_id: "chat-anon:#{digest}", agent_person_id: visitor.person!.id)
    assert_equal "chat-anon:#{digest}", visitor.author_ref
    assert_equal visitor.person!, AgentChat::Visitor.new("alex", anon_token: ANON).person!
    assert_nil visitor.anon_thread_key, "a signed-out visitor folds nothing"
  end

  test "a signed-in visitor carrying an anon token names the anon thread to fold" do
    visitor = AgentChat::Visitor.new("alex", email: "fold@example.com", anon_token: ANON)
    assert_equal "chat:alex:anon:#{AgentChat.anon_digest(ANON)}", visitor.anon_thread_key
  end

  test "a person param that names nobody, or names them badly, is refused" do
    assert_raises(AgentChat::Visitor::Invalid) { AgentChat::Visitor.new("alex") }
    assert_raises(AgentChat::Visitor::Invalid) { AgentChat::Visitor.new("alex", email: "not-an-email") }
    assert_raises(AgentChat::Visitor::Invalid) { AgentChat::Visitor.new("alex", anon_token: "short") }
    assert_raises(AgentChat::Visitor::Invalid) { AgentChat::Visitor.from_param("alex", "a string") }
  end

  test "the allow-list: an app reaches only the souls it lists that also have a web chat" do
    routes = AgentMessages::Routes.new("web" => { "souls" => %w[alex avi], "apps" => { "alex-build" => %w[alex tywin] } })

    assert AgentChat.available?("alex-build", "alex", routes: routes)
    refute AgentChat.available?("alex-build", "avi", routes: routes), "a web soul the app does not list"
    refute AgentChat.available?("alex-build", "tywin", routes: routes), "a listed soul with no web chat"
    refute AgentChat.available?("turf-monster", "alex", routes: routes), "an app not listed at all"
    refute AgentChat.available?("alex-build", "Alex; drop", routes: routes)
  end

  test "the shipped config lets alex-build chat with Alex" do
    assert AgentChat.available?("alex-build", "alex", routes: AgentMessages::Routes.load)
  end
end

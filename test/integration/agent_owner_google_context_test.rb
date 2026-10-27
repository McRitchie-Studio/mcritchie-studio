require "test_helper"
require "support/google_connect_fakes"
require_relative "../support/client_cto_fixtures"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] An app owner's message to their client CTO, through the REAL
# mailbox API in process: WebIngest stores it, the worker claims it, GETs its
# context bundle (holder-only), and the ContextBuilder prints the owner's own
# calendar event, read from a STUBBED Google connection, inside the fence.
# Nothing reaches Google or Claude.
class AgentOwnerGoogleContextTest < ActionDispatch::IntegrationTest
  include ClientCtoFixtures
  include GoogleConnectFakes

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @pawsome = client_app!(slug: "pawsome", name: "Pawsome")
    @owner = User.create!(email: "pat@pawsome.example", name: "Pat Owner", role: "viewer")
    AppMembership.create!(app: @pawsome, user: @owner)
  end

  teardown do
    AgentMessages::Answerers.reset!
    reset_google_connect
  end

  def ask(user, text) = AgentMessages::WebIngest.new(user: user, cto: AppOwnership.cto_for_app("pawsome")).call(text)

  def claimed_context(message)
    @client.claim(worker: "laptop-1", channel: "web", soul: "client_cto")
    @client.context(message.id, worker: "laptop-1")["data"]
  end

  test "the owner's bundle carries their calendar event, and the prompt prints it inside the fence" do
    with_connect_env do
      store_google(email: "pat@example.com", scope: SCOPE, user: @owner)
      google_answers(200, { access_token: "ya29.synthetic" })
      google_reads(GoogleConnect::CalendarReader::EVENTS_URL => [ 200, { items: [
        { id: "e1", summary: "Groomer supplier call", start: { dateTime: "2026-10-28T15:00:00Z" }, end: { dateTime: "2026-10-28T16:00:00Z" } }
      ] } ])

      message = ask(@owner, "What's on my calendar this week?")
      assert_equal "received", message.status
      context = claimed_context(message)

      assert_equal [ "Groomer supplier call" ], context.dig("google_context", "calendar", "events").map { _1["title"] }
      prompt = AgentMailbox::ContextBuilder.new(soul: "client_cto", message: { "channel" => "web", "author_name" => "Pat",
                                                                                "content" => message.content },
                                                context: context, fence: "untrusted-int1").prompt
      assert_match(%r{== GOOGLE: .*?<untrusted-int1>\n.*Groomer supplier call.*?</untrusted-int1>}m, prompt)
      refute_match(/ya29|1\/\/synthetic/, context.to_json + prompt)
    end
  end
end

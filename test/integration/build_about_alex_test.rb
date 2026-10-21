require "test_helper"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] ritch-answers-about-alex: a visitor asks a /build chat about
# Alex. bin/dispatcher's loop claims the row through the REAL mailbox API in
# process, prompts a STUBBED Claude (which receives Alex's profile and its
# rules), and completes it with an answer about Alex: the row stores no intake
# card and records no intake_card event, and the request's steps stay unset.
# Nothing reaches Discord, Claude or production.
class BuildAboutAlexTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  REPLY = "Alex McRitchie founded McRitchie Studio. Alex's take is that time is the metric that matters. " \
          "What would you like to build?".freeze

  class StubClaude
    attr_reader :prompts

    def initialize = @prompts = Queue.new

    def call(_argv, stdin:, timeout:, chdir:)
      return [ "board: quiet", 0 ] if stdin.nil?

      @prompts << stdin
      [ REPLY, 0, "" ]
    end
  end

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  test "a question about Alex is answered from his profile with no intake card" do
    proof = BrowserProof.new(BuildController::PROOF_PURPOSE).issue(5.seconds.ago).reverse
    post build_path, params: { app_request: { prompt: "Who is Alex, and what does he think about building?",
                                              client_id: "alex-0001", form_proof: proof } }
    request_row = AppRequest.recent.first
    message = AgentMessage.find_by!(thread_key: BuildIntake.thread_key(request_row.token))

    runner = StubClaude.new
    disp = AgentMailbox::Dispatcher.new(client: @client, souls: AgentMailbox.routed_souls, worker: "disp-alex-1", runner: runner,
                                        channel: nil, claude_cmd: %w[fake-claude], out: @out, clock: -> { Time.now },
                                        sleeper: ->(_) { }, idle_wait: 0, busy_wait: 0, version: "test")
    200.times do
      disp.tick
      break if message.reload.status == "completed" && disp.runs.empty?

      sleep 0.01
    end
    assert_equal "completed", message.reload.status, "never answered; log:\n#{@out.string}"

    sent = runner.prompts.pop
    assert_includes sent, "- ABOUT ALEX.", "the model is given the about-Alex rules"
    assert_includes sent, "Alex McRitchie is the founder of McRitchie Studio", "and Alex's profile"
    assert_includes sent, "Politely decline anything more about his family"

    assert_equal REPLY, message.response_text
    assert_nil message.intake_card, "an answer about Alex shows no card"
    refute message.events.where(kind: "intake_card").exists?, "and records none"
    refute request_row.reload.intake_complete?
  end
end

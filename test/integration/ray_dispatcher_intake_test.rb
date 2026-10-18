require "test_helper"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] ray-slug-rename: the orchestrator's soul slug is `ray`. A visitor's
# first /build message is routed to `ray`, and bin/dispatcher's loop
# (AgentMailbox::Dispatcher), serving the souls config/agent_routes.yml routes,
# claims it through the REAL mailbox API in process, answers it with a STUBBED
# Claude prompted as Ray, and completes it. A dispatcher still running a
# pre-rename config (serving `xan`) is handed the same row through the claim
# alias (Task::SOUL_ALIASES), so no /build visitor waits on a soul nobody serves
# between the deploy and the dispatcher's own restart. Nothing reaches Discord,
# Claude or production.
class RayDispatcherIntakeTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Answers every Claude call with Ray's opening line and keeps the prompt.
  class StubClaude
    attr_reader :prompts

    def initialize = @prompts = Queue.new

    def call(_argv, stdin:, timeout:, chdir:)
      return [ "board: quiet", 0 ] if stdin.nil?

      @prompts << stdin
      [ "Hi! What would you like to build?", 0, "" ]
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

  def first_build_message
    proof = BrowserProof.new(BuildController::PROOF_PURPOSE).issue(5.seconds.ago).reverse
    post build_path, params: { app_request: { prompt: "A league site with standings", client_id: "ray-0001", form_proof: proof } }
    request_row = AppRequest.recent.first
    AgentMessage.find_by!(thread_key: BuildIntake.thread_key(request_row.token))
  end

  def dispatcher(souls:, runner:)
    AgentMailbox::Dispatcher.new(client: @client, souls: souls, worker: "disp-ray-1", runner: runner, channel: nil,
                                 claude_cmd: %w[fake-claude], out: @out, clock: -> { Time.now },
                                 sleeper: ->(_) { }, idle_wait: 0, busy_wait: 0, version: "test")
  end

  def drive(disp, ticks: 200)
    ticks.times do
      disp.tick
      return if yield

      sleep 0.01
    end
    flunk "condition never held; log:\n#{@out.string}"
  end

  test "the dispatcher serves ray, not xan, and answers a /build intake turn as Ray" do
    souls = AgentMailbox.routed_souls
    assert_includes souls, "ray"
    refute_includes souls, "xan", "the retired slug is no longer a served soul"

    message = first_build_message
    assert_equal "ray", message.soul_slug, "the /build intake routes to the ray soul"

    runner = StubClaude.new
    disp = dispatcher(souls: souls, runner: runner)
    drive(disp) { message.reload.status == "completed" && disp.runs.empty? }

    assert_equal "Hi! What would you like to build?", message.response_text
    assert_equal "disp-ray-1", message.claimed_by
    assert_match(/You are Ray/, runner.prompts.pop, "Claude is prompted as Ray, by the roster's name")
    assert_includes AgentDispatcher.find_by!(worker_id: "disp-ray-1").souls, "ray"
  end

  test "a dispatcher still serving the retired xan slug is handed ray's row" do
    message = first_build_message

    runner = StubClaude.new
    disp = dispatcher(souls: %w[xan], runner: runner)
    drive(disp) { message.reload.status == "completed" && disp.runs.empty? }

    assert_equal "ray", message.soul_slug, "the row keeps its canonical soul"
    assert_equal "Hi! What would you like to build?", message.response_text
  end
end

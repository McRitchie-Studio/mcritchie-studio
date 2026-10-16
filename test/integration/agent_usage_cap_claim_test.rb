require "test_helper"
require_relative "../support/agent_message_fixtures"

# [integration] The usage gate inside the atomic claim (AgentMessage.claim!,
# AgentUsage.gate): a client's message to an app at its monthly allowance is
# answered in code with the cap reply (completed, `usage_capped`, the reply
# queued, no run), and the claim moves on to the next message; a message past
# the warn share is claimed with a `usage_warned` event and its answer ends with
# the code's notice; the owner's message is claimed whatever the meter says.
class AgentUsageCapClaimTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ActiveJob::TestHelper

  setup do
    @app = apps(:turf_monster)
    @app.update!(package_tier: "builder", cto_cap_lifted_at: nil)
    @client = AgentPerson.create!(display_name: "Client", role: "client", client_domain: "turf_monster")
    @owner = AgentPerson.create!(display_name: "Owner", role: "owner")
    @packages = [ WorkspacePackage.new({ "key" => "builder", "name" => "Builder", "price_monthly" => 100, "cto_monthly_tokens" => 1_000 }),
                  WorkspacePackage.new({ "key" => "pro", "name" => "Pro", "price_monthly" => 500, "cto_monthly_tokens" => 5_000 }) ]
  end

  def spent!(tokens)
    row = agent_message!(soul: "turf_monster", person: @client, status: "completed", completed_at: 1.hour.ago,
                         thread_key: "discord:spent:#{tokens}")
    row.update_columns(run_meta: { "input_tokens" => tokens, "audience" => "client" })
  end

  test "at the cap: answered in code, reply queued, nothing metered, and the next message is claimed" do
    spent!(1_000)
    WorkspacePackage.stub(:all, @packages) do
      capped = agent_message!(soul: "turf_monster", person: @client, thread_key: "discord:a:1")
      owners = agent_message!(soul: "turf_monster", person: @owner, thread_key: "discord:b:1")

      result = nil
      assert_enqueued_with(job: AgentMessageReplyJob, args: [ capped.id ]) do
        result = AgentMessage.claim!(soul: "turf_monster", worker: "w1")
      end

      assert_equal owners.id, result.message.id
      capped.reload
      assert_equal "completed", capped.status
      assert_equal "queued", capped.reply_status
      assert_nil capped.claimed_by
      assert_match(/used its monthly agent allowance/, capped.response_text)
      assert_match(/Pro \(\$500\/month\) raises it/, capped.response_text)
      assert_equal %w[usage_capped], capped.events.pluck(:kind)
      assert_equal 1_000, AgentUsage.meter(@app).used
      assert_equal 1, AgentUsage.meter(@app).totals.messages
    end
  end

  test "past the warn share: claimed, warned, and the answer ends with the notice" do
    spent!(850)
    WorkspacePackage.stub(:all, @packages) do
      message = agent_message!(soul: "turf_monster", person: @client, thread_key: "discord:c:1")
      result = AgentMessage.claim!(soul: "turf_monster", worker: "w1")
      assert_equal message.id, result.message.id
      assert message.events.exists?(kind: "usage_warned")

      message.reload.complete!(worker: "w1", response_text: "Here you go.",
                               run: { run_meta: { "input_tokens" => 10, "audience" => "owner" } })
      message.reload
      assert_match(/\AHere you go\.\n\n_85% of this app's monthly agent allowance is used\./, message.response_text)
      assert_equal "client", message.run_meta["audience"], "the board stamps the audience, not the worker"
    end
  end

  test "no allowance configured: a client's message is claimed with no notice" do
    spent!(1_000_000)
    message = agent_message!(soul: "turf_monster", person: @client, thread_key: "discord:d:1")
    assert_equal message.id, AgentMessage.claim!(soul: "turf_monster", worker: "w1").message.id
    message.reload.complete!(worker: "w1", response_text: "Fine.")
    assert_equal "Fine.", message.reload.response_text
  end

  test "the public reads a plain cap reply and never the meter's notice" do
    spent!(1_000)
    visitor = AgentPerson.create!(display_name: "Visitor", role: "public")
    WorkspacePackage.stub(:all, @packages) do
      capped = agent_message!(soul: "turf_monster", person: visitor, thread_key: "discord:e:1")
      AgentMessage.claim!(soul: "turf_monster", worker: "w1")
      capped.reload
      assert_equal "completed", capped.status
      assert_match(/\AI can't answer right now\. Please try again after Nov 1\.\z/, capped.response_text)
      assert_no_match(/\$|allowance|upgrade/i, capped.response_text)
    end

    spent_more = AgentMessage.where(person: @client).first
    spent_more.update_columns(run_meta: { "input_tokens" => 850, "audience" => "client" })
    WorkspacePackage.stub(:all, @packages) do
      warned = agent_message!(soul: "turf_monster", person: visitor, thread_key: "discord:f:1")
      AgentMessage.claim!(soul: "turf_monster", worker: "w2")
      assert warned.events.exists?(kind: "usage_warned")
      warned.reload.complete!(worker: "w2", response_text: "Hello.")
      assert_equal "Hello.", warned.reload.response_text, "no meter notice on a public answer"
    end
  end
end

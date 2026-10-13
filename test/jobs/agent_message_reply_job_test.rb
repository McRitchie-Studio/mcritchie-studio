require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] + [integration] AgentMessageReplyJob — the answer goes back to Discord
# once: as a reply to the original, signed with the soul's name, carrying the
# row's stable nonce with enforce_nonce, and never again once posted.
class AgentMessageReplyJobTest < ActiveJob::TestCase
  include AgentMessageFixtures

  def completed_message
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "Release rel-1 is green.")
    message.reload
  end

  # The bot's one network seam, swapped for the block. (Minitest's `stub` would
  # CALL a lambda value instead of returning it, so this sets the attribute.)
  def with_transport(transport)
    previous = AgentMessages::DiscordBot.transport
    AgentMessages::DiscordBot.transport = transport
    yield
  ensure
    AgentMessages::DiscordBot.transport = previous
  end

  def recording_transport(posts, id: "880000000000000001")
    lambda do |method, url, headers, body|
      posts << { method: method, url: url, auth: headers["Authorization"], body: JSON.parse(body) }
      [ 200, JSON.generate("id" => id) ]
    end
  end

  test "[integration] complete twice posts once: a reply referencing the original, nonce enforced" do
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload
    posts = []

    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_transport(recording_transport(posts)) do
        perform_enqueued_jobs do
          message.complete!(worker: "w1", response_text: "Release rel-1 is green.")
          message.complete!(worker: "w1", response_text: "Release rel-1 is green.")
        end
        AgentMessageReplyJob.perform_now(message.id) # a stray retry after success
      end
    end

    assert_equal 1, posts.size
    post = posts.first
    assert_equal :post, post[:method]
    assert_equal "https://discord.com/api/v10/channels/#{DESK}/messages", post[:url]
    assert_equal "Bot test-token", post[:auth]
    assert_equal message.external_id, post[:body]["message_reference"]["message_id"]
    assert_equal "agentmsg-#{message.id}", post[:body]["nonce"]
    assert_equal true, post[:body]["enforce_nonce"]
    assert_equal [], post[:body]["allowed_mentions"]["parse"], "an answer never pings a role or @everyone"
    assert_match(/\A\*\*Avi\*\* · Release rel-1 is green\./, post[:body]["content"])

    message.reload
    assert_equal "880000000000000001", message.reply_external_id
    assert message.reply_posted_at
    assert_equal "reply_posted", message.events.last.kind
    assert_equal message.reply_url, message.events.last.detail["url"]
  end

  test "[unit] a retry after a lost response re-sends the SAME nonce" do
    message = completed_message
    posts = []
    flaky = lambda do |method, url, headers, body|
      posts << JSON.parse(body)
      raise AgentMessages::DiscordBot::Error, "Discord unreachable: Net::ReadTimeout" if posts.size == 1

      recording_transport([]).call(method, url, headers, body)
    end

    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_transport(flaky) do
        assert_raises(AgentMessages::DiscordBot::Error) { AgentMessageReplyJob.new.perform(message.id) }
        AgentMessageReplyJob.new.perform(message.id)
      end
    end

    assert_equal 2, posts.size
    assert_equal posts.first["nonce"], posts.last["nonce"]
    assert message.reload.reply_external_id
  end

  test "[unit] without a bot token the reply is skipped and recorded, the answer kept" do
    message = completed_message
    with_env("DISCORD_AGENT_BOT_TOKEN", nil) { AgentMessageReplyJob.perform_now(message.id) }

    message.reload
    assert_nil message.reply_external_id
    assert_equal "Release rel-1 is green.", message.response_text
    assert_equal "reply_skipped", message.events.last.kind
  end

  test "[unit] a message that is not completed is never replied to" do
    message = agent_message!
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_transport(->(*) { flunk "nothing to post" }) do
        AgentMessageReplyJob.perform_now(message.id)
      end
    end
    assert_nil message.reload.reply_external_id
  end

  test "[unit] a long answer is clipped to Discord's limit" do
    clipped = AgentMessages::DiscordBot.clip("x" * 2500)
    assert_equal 2000, ReleaseNotes::DiscordClient.discord_length(clipped)
    assert clipped.end_with?("…")
  end
end

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
    assert_equal "posted", message.reply_status
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
    assert_equal "skipped", message.reply_status
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

  test "[unit] a completed message is queued for its reply, and spent retries mark it failed" do
    message = completed_message
    assert_equal "queued", message.reply_status

    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_transport(->(*) { [ 500, "boom" ] }) do
        perform_enqueued_jobs { AgentMessageReplyJob.perform_later(message.id) }
      end
    end

    message.reload
    assert_equal "failed", message.reply_status
    assert_equal "reply_failed", message.events.last.kind
    assert_match(/HTTP 500/, message.events.last.detail["error"])
  end

  SHARED = "shared-token-AAAA".freeze
  AVI_TOKEN = "avi-own-token-BBBB".freeze

  # Both ENV vars set (or cleared) for the block.
  def with_tokens(shared: SHARED, avi: AVI_TOKEN, &)
    with_env("DISCORD_AGENT_BOT_TOKEN", shared) { with_env("DISCORD_BOT_TOKEN_AVI", avi, &) }
  end

  # Answers per bot: `refuse` maps an Authorization header to an HTTP status.
  def bot_transport(posts, refuse: {})
    lambda do |method, url, headers, body|
      posts << { auth: headers["Authorization"], body: JSON.parse(body) }
      status = refuse[headers["Authorization"]]
      next [ status, JSON.generate("message" => "Missing Access", "code" => 50_001) ] if status

      recording_transport([]).call(method, url, headers, body)
    end
  end

  test "[unit] the ENV name is DISCORD_BOT_TOKEN_ plus the soul slug, upcased" do
    bot = AgentMessages::DiscordBot
    assert_equal "DISCORD_BOT_TOKEN_AVI", bot.soul_token_env("avi")
    assert_equal "DISCORD_BOT_TOKEN_TURF_MONSTER", bot.soul_token_env("turf_monster")
    assert_equal "DISCORD_BOT_TOKEN_TYRION", bot.soul_token_env("tyrion")
    with_env("DISCORD_BOT_TOKEN_TYRION", nil) { assert_nil bot.soul_token("tyrion") }
    with_env("DISCORD_BOT_TOKEN_AVI", "  ") { assert_nil bot.soul_token("avi"), "blank is absent" }
    with_env("DISCORD_BOT_TOKEN_AVI", " t1 ") { assert_equal "t1", bot.soul_token("avi") }
    assert_nil bot.soul_token(nil)
  end

  test "[unit] a soul with its own token replies as its own bot, unsigned" do
    message = completed_message
    posts = []
    with_tokens { with_transport(bot_transport(posts)) { AgentMessageReplyJob.perform_now(message.id) } }

    assert_equal 1, posts.size
    assert_equal "Bot #{AVI_TOKEN}", posts.first[:auth]
    assert_equal "Release rel-1 is green.", posts.first[:body]["content"], "no **Avi** · prefix on the soul's own bot"
    assert_equal "agentmsg-#{message.id}", posts.first[:body]["nonce"]
    assert_equal [ "posted", "soul_bot" ], [ message.reload.reply_status, message.events.last.detail["via"] ]
  end

  test "[unit] a blank or absent soul token falls back to the shared bot, signed" do
    [ nil, "", "   " ].each do |blank|
      message = completed_message
      posts = []
      with_tokens(avi: blank) { with_transport(bot_transport(posts)) { AgentMessageReplyJob.perform_now(message.id) } }

      assert_equal [ "Bot #{SHARED}" ], posts.map { |p| p[:auth] }, blank.inspect
      assert_equal "**Avi** · Release rel-1 is green.", posts.first[:body]["content"]
      assert_equal "shared_bot", message.reload.events.last.detail["via"]
    end
  end

  test "[unit] a soul with no token of its own (Tyrion) still answers through the shared bot" do
    message = agent_message!(soul: "tyrion")
    AgentMessage.claim!(soul: "tyrion", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "Your move.")
    posts = []
    with_tokens { with_env("DISCORD_BOT_TOKEN_TYRION", nil) { with_transport(bot_transport(posts)) { AgentMessageReplyJob.perform_now(message.id) } } }
    assert_equal [ "Bot #{SHARED}" ], posts.map { |p| p[:auth] }
    assert_match(/\A\*\*[^*]+\*\* · Your move\.\z/, posts.first[:body]["content"])
  end

  [ 401, 403 ].each do |status|
    test "[unit] a #{status} on the soul's own bot falls back once to the shared bot and writes an ErrorLog" do
      message = completed_message
      posts = []
      with_tokens do
        with_transport(bot_transport(posts, refuse: { "Bot #{AVI_TOKEN}" => status })) do
          assert_difference -> { ErrorLog.where(target: message).count }, 1 do
            AgentMessageReplyJob.perform_now(message.id)
          end
        end
      end

      assert_equal [ "Bot #{AVI_TOKEN}", "Bot #{SHARED}" ], posts.map { |p| p[:auth] }, "one try each, in that order"
      assert_equal "**Avi** · Release rel-1 is green.", posts.last[:body]["content"]
      assert_equal posts.first[:body]["nonce"], posts.last[:body]["nonce"]
      message.reload
      assert_equal "posted", message.reply_status
      refused = message.events.find_by!(kind: "reply_bot_refused")
      assert_equal "DISCORD_BOT_TOKEN_AVI", refused.detail["token_env"]
      assert_match(/HTTP #{status}/, refused.detail["error"])
      assert ErrorLog.where(target: message).last.inspect.start_with?("#<AgentMessages::DiscordBot::Unauthorized:")
    end
  end

  test "[unit] once refused, a retried job goes straight to the shared bot: never a loop on the soul's bot" do
    message = completed_message
    posts = []
    shared_down = 0
    transport = lambda do |method, url, headers, body|
      posts << headers["Authorization"]
      next [ 403, "{}" ] if headers["Authorization"] == "Bot #{AVI_TOKEN}"

      shared_down += 1
      next [ 502, "bad gateway" ] if shared_down == 1

      recording_transport([]).call(method, url, headers, body)
    end
    with_tokens do
      with_transport(transport) do
        assert_raises(AgentMessages::DiscordBot::Error) { AgentMessageReplyJob.new.perform(message.id) }
        AgentMessageReplyJob.new.perform(message.id)
      end
    end
    assert_equal [ "Bot #{AVI_TOKEN}", "Bot #{SHARED}", "Bot #{SHARED}" ], posts
    assert_equal 1, ErrorLog.where(target: message).count
    assert_equal "posted", message.reload.reply_status
  end

  # Only a refusal falls back: a timeout may have posted already, and the shared
  # bot's nonce cannot dedupe a message the soul's bot created.
  test "[unit] a soul bot timeout retries the SAME bot and nonce, never the shared bot" do
    message = completed_message
    posts = []
    transport = lambda do |method, url, headers, body|
      posts << [ headers["Authorization"], JSON.parse(body)["nonce"] ]
      raise AgentMessages::DiscordBot::Error, "Discord unreachable: Net::ReadTimeout" if posts.size == 1

      recording_transport([]).call(method, url, headers, body)
    end
    with_tokens do
      with_transport(transport) do
        assert_raises(AgentMessages::DiscordBot::Error) { AgentMessageReplyJob.new.perform(message.id) }
        AgentMessageReplyJob.new.perform(message.id)
      end
    end
    nonce = "agentmsg-#{message.id}"
    assert_equal [ [ "Bot #{AVI_TOKEN}", nonce ], [ "Bot #{AVI_TOKEN}", nonce ] ], posts
    assert_not message.reload.events.exists?(kind: "reply_bot_refused")
    assert_equal "soul_bot", message.events.last.detail["via"]
  end

  test "[unit] refused with no shared bot set: failed and recorded, never dropped silently" do
    message = completed_message
    with_tokens(shared: nil) do
      with_transport(->(*) { [ 401, "{}" ] }) { AgentMessageReplyJob.perform_now(message.id) }
    end
    message.reload
    assert_equal "failed", message.reply_status
    assert_equal "reply_failed", message.events.last.kind
    assert_equal 1, ErrorLog.where(target: message).count
  end

  test "[unit] no token appears in any event, ErrorLog, raised message, log line or inspect" do
    message = completed_message
    echo = lambda do |_m, _u, headers, _b|
      [ 403, JSON.generate("message" => "denied for #{headers['Authorization']}") ] # a body that echoes the token
    end
    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    raised = nil
    begin
      with_tokens(shared: SHARED) do
        with_transport(echo) do
          AgentMessageReplyJob.new.perform(message.id)
        rescue AgentMessages::DiscordBot::Error => e
          raised = e
        end
        inspected = AgentMessages::DiscordBot.new(token: AVI_TOKEN).inspect
        refute_includes inspected, AVI_TOKEN
      end
    ensure
      Rails.logger = previous_logger
    end

    assert raised, "the shared bot was refused too"
    texts = [ raised.message, log.string ] +
            message.reload.events.map { |e| e.detail.to_json } +
            ErrorLog.where(target: message).flat_map { |row| [ row.message, row.inspect, row.attributes.to_json ] }
    texts.each do |text|
      refute_includes text, AVI_TOKEN
      refute_includes text, SHARED
    end
    assert_includes message.events.find_by!(kind: "reply_bot_refused").detail["error"], "[REDACTED]"
  end

  test "[unit] a long answer is clipped to Discord's limit" do
    clipped = AgentMessages::DiscordBot.clip("x" * 2500)
    assert_equal 2000, ReleaseNotes::DiscordClient.discord_length(clipped)
    assert clipped.end_with?("…")
  end
end

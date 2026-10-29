require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] The medium seam (Media): the registry resolves each medium the hub
# speaks, every adapter dispatches to the code it wraps, the jobs pick the
# adapter by the row's own channel, and the error hierarchy keeps the jobs'
# retry and drop rules exactly as they were.
class MediaTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  test "[unit] the registry resolves discord, email and web to their adapters, each keyed by itself" do
    assert_equal %w[discord email web], Media.keys
    { "discord" => Media::Discord, "email" => Media::Email, "web" => Media::Web }.each do |key, klass|
      adapter = Media.adapter(key)
      assert_instance_of klass, adapter
      assert_kind_of Media::Adapter, adapter
      assert_equal key, adapter.key
      assert Media.registered?(key)
    end
    assert_instance_of Media::Discord, Media.adapter(:discord), "a symbol key resolves too"
  end

  test "[unit] an unknown medium raises UnknownMedium, a Media::Error naming the known keys" do
    refute Media.registered?("slack")
    error = assert_raises(Media::UnknownMedium) { Media.adapter("slack") }
    assert_kind_of Media::Error, error
    assert_includes error.message, "discord, email, web"
  end

  test "[unit] the registry covers every channel a message may hold, and typing matches TYPING_CHANNELS" do
    assert_equal AgentMessage::CHANNELS.sort, Media.keys.sort
    typing = Media.keys.select { |key| Media.adapter(key).supports?(:typing) }
    assert_equal AgentMessage::TYPING_CHANNELS.sort, typing.sort
    assert(Media.keys.all? { |key| Media.adapter(key).supports?(:reply) })
  end

  test "[unit] the error hierarchy: DiscordBot errors are Media errors, so the jobs retry and drop the same set" do
    assert_operator Media::Error, :<, StandardError
    assert_operator AgentMessages::DiscordBot::Error, :<, Media::Error
    assert_operator AgentMessages::DiscordBot::Unauthorized, :<, Media::Error
    assert_operator AgentMessages::DiscordBot::RateLimited, :<, Media::Error
    retried = AgentMessageReplyJob.rescue_handlers.map(&:first)
    assert_includes retried, "Media::Error"
    refute_includes retried, "AgentMessages::DiscordBot::Error", "one retry rule, not two"
  end

  test "[unit] the base adapter's unbuilt hooks raise NotImplementedError; typing is a no-op" do
    adapter = Media::Adapter.new
    assert_raises(NotImplementedError) { adapter.key }
    assert_raises(NotImplementedError) { adapter.deliver_reply(Object.new) }
    assert_raises(NotImplementedError) { adapter.post("home", "text") }
    assert_raises(NotImplementedError) { adapter.inbound_mode }
    assert_raises(NotImplementedError) { adapter.configured? }
    assert_nil adapter.typing(Object.new, phase: "typing")
    assert_nil adapter.message_url(Object.new)
    assert_nil adapter.setup_kit
    %w[discord email web].each { |key| assert_raises(NotImplementedError) { Media.adapter(key).post("home", "text") } }
  end

  test "[unit] each adapter states its inbound mode, setup kit and configuration" do
    assert_equal :gateway, Media.adapter("discord").inbound_mode
    assert_equal :webhook, Media.adapter("email").inbound_mode
    assert_equal :http, Media.adapter("web").inbound_mode
    assert_equal "discord_bot", Media.adapter("discord").setup_kit
    assert_equal AgentSetups::DiscordBotKit, AgentSetups::Kits.fetch(Media.adapter("discord").setup_kit)
    with_env("DISCORD_AGENT_BOT_TOKEN", nil) { refute Media.adapter("discord").configured? }
    with_env("DISCORD_AGENT_BOT_TOKEN", "t") { assert Media.adapter("discord").enabled? }
    assert Media.adapter("email").configured?
    assert Media.adapter("web").configured?
  end

  test "[unit] Discord's message_url is the row's Discord link; email and web have none" do
    message = agent_message!
    assert_equal message.discord_url, Media.adapter("discord").message_url(message)
    assert_equal message.discord_url("123"), Media.adapter("discord").message_url(message, "123")
    assert_nil Media.adapter("email").message_url(message)
    assert_nil Media.adapter("web").message_url(message)
  end

  test "[unit] Email and Web deliver_reply hand the row to EmailReply and WebChat" do
    message = Object.new
    seen = []
    AgentMessages::EmailReply.stub(:deliver!, ->(m) { seen << [ :email, m ] and :posted }) do
      assert_equal :posted, Media.adapter("email").deliver_reply(message)
    end
    AgentMessages::WebChat.stub(:deliver!, ->(m) { seen << [ :web, m ] and :delivered }) do
      assert_equal :delivered, Media.adapter("web").deliver_reply(message)
    end
    assert_equal [ [ :email, message ], [ :web, message ] ], seen
  end

  test "[unit] Web typing broadcasts the pulse with its phase; Email typing does nothing" do
    message = Object.new
    seen = []
    AgentMessages::WebChat.stub(:broadcast_typing, ->(m, phase:) { seen << [ m, phase ] }) do
      Media.adapter("web").typing(message, phase: "thinking")
    end
    assert_equal [ [ message, "thinking" ] ], seen
    assert_nil Media.adapter("email").typing(message, phase: "typing")
  end

  test "[unit] the reply job dispatches by the row's own channel, and leaves an unregistered one alone" do
    message = agent_message!(status: "completed", channel: "web", response_text: "hi")
    calls = []
    fake = Struct.new(:calls) { def deliver_reply(m) = calls << m.id }.new(calls)
    Media.stub(:adapter, ->(key) { calls << key and fake }) do
      AgentMessageReplyJob.perform_now(message.id)
    end
    assert_equal [ "web", message.id ], calls

    message.update_column(:channel, "slack")
    Media.stub(:adapter, ->(_key) { flunk "an unregistered medium must not resolve" }) do
      assert_nil AgentMessageReplyJob.perform_now(message.id)
    end
  end

  test "[unit] the typing job passes the allow-listed phase to the row's adapter" do
    message = agent_message!(channel: "web")
    AgentMessage.claim!(soul: "avi", worker: "w1")
    seen = []
    fake = Struct.new(:seen) { def typing(m, phase:) = seen << [ m.id, phase ] }.new(seen)
    message.stub(:typing_refusal, nil) do
      AgentMessage.stub(:find_by, message) do
        Media.stub(:adapter, ->(key) { seen << key and fake }) do
          AgentMessageTypingJob.perform_now(message.id, "w1", "thinking")
          AgentMessageTypingJob.perform_now(message.id, "w1", "bogus")
        end
      end
    end
    assert_equal [ "web", [ message.id, "thinking" ], "web", [ message.id, "typing" ] ], seen
  end

  test "[unit] the shared bot signs with the display name through the job's kept class methods" do
    message = agent_message!(status: "completed", response_text: "the answer")
    name = Media.display_name("avi")
    assert_equal name, AgentMessageReplyJob.display_name("avi")
    assert_equal "**#{name}** · the answer", AgentMessageReplyJob.reply_text(message)
    assert_equal "the answer", AgentMessageReplyJob.reply_text(message, signed: false)
    assert_equal AgentMessageReplyJob::REFUSED_EVENT, "reply_bot_refused"
    assert_equal AgentMessageTypingJob::REFUSED_EVENT, "typing_bot_refused"
  end
end

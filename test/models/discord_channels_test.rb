require "test_helper"

# [unit] DiscordChannels — the two lanes the app posts to, split by who the
# message comes from. A lane's webhook is a secret read from ENV; an unset lane
# is nil (callers skip), and an unknown lane is a typo that raises.
class DiscordChannelsTest < ActiveSupport::TestCase
  def with_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original
  end

  test "two lanes, external and internal, each with its own env var, channel and 1Password field" do
    assert_equal %i[external internal], DiscordChannels::LANES.keys
    envs = DiscordChannels::LANES.values.map { |lane| lane[:env] }
    assert_equal envs.uniq, envs, "the two lanes must never share a webhook"
    assert_equal "#external-communication", DiscordChannels.channel_label(:external)
    assert_equal "internal-communication-webhook", DiscordChannels.lane(:internal)[:op_field]
  end

  test "a lane resolves its webhook from its own env var, and nil when unset or blank" do
    with_env("DISCORD_EXTERNAL_WEBHOOK_URL", "https://discord.example/webhooks/ext") do
      assert_equal "https://discord.example/webhooks/ext", DiscordChannels.webhook_url(:external)
      assert DiscordChannels.configured?(:external)
    end
    with_env("DISCORD_EXTERNAL_WEBHOOK_URL", "  ") { assert_nil DiscordChannels.webhook_url(:external) }
    with_env("DISCORD_EXTERNAL_WEBHOOK_URL", nil) { refute DiscordChannels.configured?(:external) }
  end

  test "an unknown lane raises rather than posting nowhere quietly" do
    error = assert_raises(DiscordChannels::UnknownLane) { DiscordChannels.webhook_url(:scratch_pad) }
    assert_match(/external, internal/, error.message)
  end
end

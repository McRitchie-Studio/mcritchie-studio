require "test_helper"

# [unit] Card-2 follow-ups (omnichannel-media epic, Status 2026-10-29 12:50):
# Media::Discord#post never lets a webhook channel with its env vars unset fall
# through to the release-notes webhook, and the release-notes API answers a
# malformed config/agent_media.yml with a named refusal instead of a 500.
class MediaDiscordPostGuardTest < ActiveSupport::TestCase
  def home(envs) = Media::Home.new(medium: "discord", channel: "external", spec: { "webhook_env" => envs }, source: "purpose:app_requests", fell_from: [])

  test "[unit] a webhook channel whose env vars are unset raises MissingWebhook, never posting to #releases" do
    delivered = []
    with_env("DISCORD_RELEASE_NOTES_WEBHOOK_URL", "https://d.example/notes") do
      with_env("GUARD_TEST_EXTERNAL", nil) do
        ReleaseNotes::DiscordClient.stub(:deliver, ->(**kw) { delivered << kw }) do
          error = assert_raises(ReleaseNotes::DiscordClient::MissingWebhook) do
            Media.adapter("discord").post(home("GUARD_TEST_EXTERNAL"), content: "a new app request")
          end
          assert_includes error.message, "GUARD_TEST_EXTERNAL"
        end
      end
    end
    assert_empty delivered, "nothing reached the release-notes webhook"
  end

  test "[unit] a set webhook is posted to by its own URL" do
    delivered = []
    with_env("GUARD_TEST_EXTERNAL", "https://d.example/external") do
      ReleaseNotes::DiscordClient.stub(:deliver, ->(**kw) { delivered << kw }) do
        Media.adapter("discord").post(home("GUARD_TEST_EXTERNAL"), content: "x")
      end
    end
    assert_equal "https://d.example/external", delivered.sole[:webhook_url]
  end
end

require "test_helper"

# [unit] AppRequestDiscordJob — a queued /build request is announced once, on the
# EXTERNAL Discord lane (#external-communication), in the background, and never
# at the funnel's expense.
class AppRequestDiscordJobTest < ActiveJob::TestCase
  def queued_request
    AppRequest.create!(prompt: "A league site with schedules", user: users(:viewer)).queue!("league-hub")
  end

  test "queueing a request enqueues the announcement, after the claim commits" do
    request_row = nil
    assert_enqueued_with(job: AppRequestDiscordJob) { request_row = queued_request }

    assert request_row.queued?
    assert_enqueued_with(job: AppRequestDiscordJob, args: [ request_row.id ])
  end

  test "without a webhook the job does nothing and the request is untouched" do
    request_row = queued_request
    with_webhook(nil) { AppRequestDiscordJob.perform_now(request_row.id) }

    assert_nil request_row.reload.discord_notified_at
  end

  test "with a webhook it posts one embed and stamps the request, so a retry never posts twice" do
    request_row = queued_request
    posts = []
    deliver = ->(**kwargs) { posts << kwargs }

    ReleaseNotes::DiscordClient.stub(:deliver, deliver) do
      with_webhook("https://discord.example/webhooks/1/abc") do
        AppRequestDiscordJob.perform_now(request_row.id)
        AppRequestDiscordJob.perform_now(request_row.id)
      end
    end

    assert_equal 1, posts.size, "a stamped request is not announced again"
    assert_equal "https://discord.example/webhooks/1/abc", posts.first[:webhook_url]
    assert request_row.reload.discord_notified_at
  end

  test "app requests post on the external lane, not the internal one" do
    assert_equal :external, AppRequestDiscordJob::LANE
    request_row = queued_request
    posts = []

    ReleaseNotes::DiscordClient.stub(:deliver, ->(**kwargs) { posts << kwargs }) do
      original = ENV["DISCORD_INTERNAL_WEBHOOK_URL"]
      ENV["DISCORD_INTERNAL_WEBHOOK_URL"] = "https://discord.example/webhooks/internal"
      begin
        with_webhook(nil) { AppRequestDiscordJob.perform_now(request_row.id) }
      ensure
        ENV["DISCORD_INTERNAL_WEBHOOK_URL"] = original
      end
    end

    assert_empty posts, "with only the internal lane configured, an app request must not leak into it"
  end

  test "the message carries the address, the prompt verbatim, the requester and the board card" do
    request_row = queued_request
    embed = AppRequestDiscordJob.embed(request_row)

    assert_includes embed[:title], "league-hub.mcritchie.studio"
    assert_equal "A league site with schedules", embed[:description]
    values = embed[:fields].map { |f| f[:value] }.join("\n")
    assert_includes values, users(:viewer).email
    assert_includes values, "/tasks/#{request_row.task_slug}"
    assert_includes values, "/build/requests"
  end

  private

  def with_webhook(value)
    key = DiscordChannels.lane(:external)[:env]
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original
  end
end

require "test_helper"

# [integration] A FEED OUTAGE HAS TO REACH A SCREEN.
#
# `Nflverse::SeedPlayers#call` recovers from an unreachable feed instead of
# aborting the ship, so every exit status stays 0 — `bin/rails runner`,
# `heroku run --exit-code`, and the post-deploy check that stamps the release
# `ok`. A green release can therefore carry data that never refreshed.
#
# The failed ImportRun that records it is durable but UNRENDERED: its only
# reader in this app is `ImportRun.last_success_for`, which selects successes.
# So this test asserts the surface, not the table — the outage has to be
# readable on /error_logs and on the Request Logs panel of /admin/dashboard,
# which is what "discoverable without querying production" means.
#
# It is also the only test in this repo that GETs /error_logs at all.
class FeedOutageErrorLogTest < ActionDispatch::IntegrationTest
  setup do
    ImportRun.delete_all
    ErrorLog.delete_all
  end

  def suffer_a_feed_outage
    importer = Nflverse::SeedPlayers.new(upload_headshots: false)
    importer.define_singleton_method(:open_source) { |_url| raise SocketError, "getaddrinfo" }
    importer.call
  end

  test "[integration] a feed outage renders on the admin error-log page" do
    suffer_a_feed_outage

    log_in_as users(:alex)
    get error_logs_path

    assert_response :success
    assert_match "SocketError", response.body,
                 "the cause has to be readable without opening a console"
    assert_match "nflverse_players", response.body,
                 "the badge has to name which importer went stale"
  end

  test "[integration] a feed outage reaches the admin dashboard request log" do
    suffer_a_feed_outage

    log_in_as users(:alex)
    get admin_dashboard_path

    assert_response :success
    assert_match "SocketError", response.body
  end

  # The page this criterion depends on has no other coverage, so its gate is
  # asserted here rather than assumed.
  test "[integration] a non-admin cannot read the error-log page" do
    log_in_as users(:viewer)
    get error_logs_path

    assert_redirected_to root_path
  end
end

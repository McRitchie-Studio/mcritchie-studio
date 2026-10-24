require "test_helper"
require_relative "../../support/daily_app_report_fixtures"

# [unit] DbBackupSweep::HerokuClient across a real socket (a TinyServer on
# 127.0.0.1 stands in for both Heroku APIs): the transfers read, the capture
# POST to the DATABASE_URL add-on, and short error reasons that never carry the
# key. Nothing reaches Heroku.
class DbBackupSweep::HerokuClientTest < ActiveSupport::TestCase
  include DailyAppReportFixtures

  KEY = "hk-secret-value".freeze
  Error = DbBackupSweep::HerokuClient::Error

  def client(server, **)
    DbBackupSweep::HerokuClient.new(token: KEY, data_api: "#{server.url}/client/v11", platform_api: server.url,
                                    open_timeout: 1, read_timeout: 1, **)
  end

  test "[unit] transfers reads the app's transfers with the bearer key" do
    server = TinyServer.new("/client/v11/apps/cyvasse/transfers" => [ 200, JSON.generate([ { "num" => 3 }, "junk" ]) ])

    assert_equal [ { "num" => 3 } ], client(server).transfers("cyvasse")
    request = server.requests.sole
    assert_equal [ "GET", "Bearer #{KEY}", "application/json" ],
                 [ request[:method], request[:headers]["authorization"], request[:headers]["accept"] ]
  ensure
    server&.close
  end

  test "[unit] capture POSTs to the heroku-postgresql add-on attached as DATABASE_URL" do
    addons = [ { "id" => "redis-1", "addon_service" => { "name" => "heroku-redis" }, "config_vars" => [ "REDIS_URL" ] },
               { "id" => "pg-follower", "addon_service" => { "name" => "heroku-postgresql" }, "config_vars" => [ "HEROKU_POSTGRESQL_RED_URL" ] },
               { "id" => "pg-primary", "addon_service" => { "name" => "heroku-postgresql" }, "config_vars" => [ "DATABASE_URL" ] } ]
    server = TinyServer.new("/apps/cyvasse/addons" => [ 200, JSON.generate(addons) ],
                            "/client/v11/databases/pg-primary/backups" => [ 201, JSON.generate("num" => 5) ])

    assert_equal({ "num" => 5 }, client(server).capture("cyvasse"))
    platform, capture = server.requests
    assert_equal "application/vnd.heroku+json; version=3", platform[:headers]["accept"]
    assert_equal [ "POST", "/client/v11/databases/pg-primary/backups" ], [ capture[:method], capture[:path] ]
  ensure
    server&.close
  end

  test "[unit] capture refuses an app with no Postgres add-on" do
    server = TinyServer.new("/apps/dads-app/addons" => [ 200, "[]" ])

    error = assert_raises(Error) { client(server).capture("dads-app") }
    assert_equal "no heroku-postgresql add-on on DATABASE_URL", error.message
  ensure
    server&.close
  end

  test "[unit] failures are short reasons that never carry the key" do
    server = TinyServer.new("/client/v11/apps/a-401/transfers" => [ 401, "{\"id\":\"unauthorized\"}" ],
                            "/client/v11/apps/a-500/transfers" => [ 503, "{}" ],
                            "/client/v11/apps/a-bad/transfers" => [ 200, "<html>" ],
                            "/client/v11/apps/a-obj/transfers" => [ 200, "{}" ],
                            "/client/v11/apps/a-hang/transfers" => :hang)
    # a-hang last: the one-thread server sleeps on it.
    reasons = %w[a-401 a-500 a-bad a-obj a-missing a-hang].map do |app|
      assert_raises(Error) { client(server).transfers(app) }.message
    end

    assert_equal [ "HTTP 401 key rejected", "HTTP 503", "unparseable response", "unexpected transfers body",
                   "HTTP 404 not found", "timeout" ], reasons
    reasons.each { |reason| refute_includes reason, KEY }
  ensure
    server&.close
  end

  test "[unit] an app name that is not a Heroku app name is refused before any request" do
    server = TinyServer.new({})
    assert_equal "bad Heroku app name", assert_raises(Error) { client(server).transfers("../apps") }.message
    assert_empty server.requests
  ensure
    server&.close
  end

  test "[unit] a refused connection is an Error, not a crash" do
    dead = DbBackupSweep::HerokuClient.new(token: KEY, data_api: "http://127.0.0.1:9/client/v11", open_timeout: 1)

    assert_match(/ECONNREFUSED|timeout/, assert_raises(Error) { dead.transfers("cyvasse") }.message)
  end
end

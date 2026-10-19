# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/client_app_host")

# [unit] ClientAppHost: which hosts are the shared client-app host's, and that
# every one of them is answered without reaching the hub
# (docs/agents/system/client-app-host.md).
class ClientAppHostTest < ActiveSupport::TestCase
  HUB = ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "hub" ] ] }

  test "[unit] the domain: env, production, QA and local defaults" do
    assert_equal "mcritchie.si", ClientAppHost.domain({}, production: true, qa: false)
    assert_nil ClientAppHost.domain({}, production: true, qa: true)
    assert_equal "localhost", ClientAppHost.domain({}, production: false, qa: false)
    assert_equal "preview.example", ClientAppHost.domain({ "CLIENT_APP_PREVIEW_DOMAIN" => " .Preview.Example " }, production: true, qa: true)
    assert_nil ClientAppHost.domain({ "CLIENT_APP_PREVIEW_DOMAIN" => "off" }, production: true, qa: false)
  end

  test "[unit] sub_for takes exactly one valid label under the domain" do
    assert_equal "pawsome", ClientAppHost.sub_for("pawsome.mcritchie.si", "mcritchie.si")
    assert_equal "my-app2", ClientAppHost.sub_for("my-app2.localhost", "localhost")
    assert_nil ClientAppHost.sub_for("mcritchie.si", "mcritchie.si")
    assert_nil ClientAppHost.sub_for("a.b.mcritchie.si", "mcritchie.si")
    assert_nil ClientAppHost.sub_for("-bad.mcritchie.si", "mcritchie.si")
    assert_nil ClientAppHost.sub_for("pawsome.mcritchie.studio", "mcritchie.si")
    assert_nil ClientAppHost.sub_for("evilmcritchie.si", "mcritchie.si")
  end

  test "[unit] preview_host? covers the apex and nested names, but never the hub's localhost" do
    assert ClientAppHost.preview_host?("mcritchie.si", "mcritchie.si")
    assert ClientAppHost.preview_host?("a.b.mcritchie.si", "mcritchie.si")
    assert_not ClientAppHost.preview_host?("localhost", "localhost")
    assert_not ClientAppHost.preview_host?("mcritchie.studio", "mcritchie.si")
    assert_not ClientAppHost.preview_host?("pawsome.mcritchie.si", nil)
  end

  test "[unit] a hub host passes through; a preview host never reaches the hub" do
    door = ClientAppHost.new(HUB, domain: "mcritchie.si")

    status, _, body = door.call(Rack::MockRequest.env_for("https://mcritchie.studio/login"))
    assert_equal [ 200, [ "hub" ] ], [ status, body.to_a ]

    %w[https://nobody-here.mcritchie.si/login https://mcritchie.si/ https://a.b.mcritchie.si/].each do |url|
      status, headers, body = door.call(Rack::MockRequest.env_for(url))
      assert_equal 404, status, url
      assert_not_includes body.to_a.join, "hub"
      assert_nil headers["set-cookie"]
    end
  end

  test "[unit] the host is off when the domain is nil" do
    door = ClientAppHost.new(HUB, domain: nil)
    status, = door.call(Rack::MockRequest.env_for("https://pawsome.mcritchie.si/"))
    assert_equal 200, status
  end

  test "[unit] url_for: https in production, the desk's port locally" do
    assert_equal "https://pawsome.mcritchie.si", ClientAppHost.url_for("pawsome", domain: "mcritchie.si", production: true)
    assert_equal "http://pawsome.localhost:3038",
                 ClientAppHost.url_for("pawsome", domain: "localhost", env: { "APP_PORT" => "3038" }, production: false)
  end
end

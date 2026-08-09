# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/edge_guard")

# [unit] EdgeGuard — the origin lockdown that makes a CDN actually load-bearing, plus
# the real-visitor-IP promotion that hangs off the same proof. See
# lib/middleware/edge_guard.rb for why the two are deliberately one switch.
class EdgeGuardTest < ActiveSupport::TestCase
  SECRET = "edge-secret-value"

  # A terminal app that records the env it was called with, so a test can assert both
  # WHETHER the request got through and what the downstream stack would have seen.
  class RecordingApp
    attr_reader :env

    def call(env)
      @env = env
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end

    def called? = !@env.nil?
  end

  def setup
    @downstream = RecordingApp.new
  end

  def env_for(path: "/tasks", headers: {})
    Rack::MockRequest.env_for("https://mcritchie.studio#{path}").merge(headers)
  end

  def call(secret: SECRET, **env_args)
    status, _headers, _body = EdgeGuard.new(@downstream, secret: secret).call(env_for(**env_args))
    status
  end

  # --- Dark by default -------------------------------------------------------------
  # This is the state the change DEPLOYS in — before the DNS cutover there is no edge
  # to require, so demanding one would refuse all real traffic.

  test "passes everything through when no secret is configured" do
    assert_equal 200, call(secret: nil)
    assert @downstream.called?, "unarmed guard must not block the request"
  end

  test "treats a blank or whitespace secret as unconfigured rather than unsatisfiable" do
    assert_equal 200, call(secret: "   ")
    assert @downstream.called?, "a blank secret must not lock the origin with no way in"
  end

  test "does not touch the client IP while unarmed" do
    call(secret: nil, headers: { "HTTP_CF_CONNECTING_IP" => "203.0.113.9", "REMOTE_ADDR" => "10.0.0.1" })

    assert_equal "10.0.0.1", @downstream.env["REMOTE_ADDR"],
                 "an unproven CF-Connecting-IP must never be believed"
  end

  # --- Armed: the lockdown ---------------------------------------------------------

  test "refuses a direct-to-origin request carrying no edge secret" do
    assert_equal 403, call
    refute @downstream.called?, "bypass traffic must not reach the app at all"
  end

  test "refuses a request presenting the wrong secret" do
    assert_equal 403, call(headers: { "HTTP_X_EDGE_SECRET" => "not-the-secret" })
    refute @downstream.called?
  end

  test "refuses a near-miss secret rather than accepting a prefix" do
    assert_equal 403, call(headers: { "HTTP_X_EDGE_SECRET" => SECRET[0..-2] })
    refute @downstream.called?
  end

  test "admits a request bearing the shared edge secret" do
    assert_equal 200, call(headers: { "HTTP_X_EDGE_SECRET" => SECRET })
    assert @downstream.called?
  end

  test "keeps the platform health check reachable without the edge" do
    assert_equal 200, call(path: "/up")
    assert @downstream.called?, "refusing /up would fail Heroku health checks, not attackers"
  end

  # --- Armed: the real visitor IP --------------------------------------------------

  test "promotes the Cloudflare client IP so throttles see the visitor" do
    call(headers: { "HTTP_X_EDGE_SECRET" => SECRET,
                    "HTTP_CF_CONNECTING_IP" => "203.0.113.9",
                    "REMOTE_ADDR" => "172.68.1.1" })

    assert_equal "203.0.113.9", @downstream.env["REMOTE_ADDR"]
    assert_equal "203.0.113.9", @downstream.env["HTTP_X_FORWARDED_FOR"],
                 "Rack::Request#ip reads X-Forwarded-For, which is what rack-attack throttles on"
  end

  test "clears a memoized remote_ip so no stale edge address survives" do
    call(headers: { "HTTP_X_EDGE_SECRET" => SECRET,
                    "HTTP_CF_CONNECTING_IP" => "203.0.113.9",
                    "action_dispatch.remote_ip" => "172.68.1.1" })

    assert_nil @downstream.env["action_dispatch.remote_ip"]
  end

  test "leaves the address alone when the edge sends no client IP" do
    call(headers: { "HTTP_X_EDGE_SECRET" => SECRET, "REMOTE_ADDR" => "172.68.1.1" })

    assert_equal "172.68.1.1", @downstream.env["REMOTE_ADDR"]
  end

  # The whole reason lockdown and IP-trust share one switch: a forged CF-Connecting-IP
  # must never be believed, and the only evidence that it is genuine is the secret.
  test "ignores a forged client IP on a request that fails the edge proof" do
    call(headers: { "HTTP_CF_CONNECTING_IP" => "1.2.3.4" })

    refute @downstream.called?, "spoofed edge headers must not buy entry"
  end
end

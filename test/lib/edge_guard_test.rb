# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/edge_guard")

# [unit] EdgeGuard — the origin lockdown that makes a CDN actually load-bearing, plus
# the real-visitor-IP promotion that hangs off the same proof. See
# lib/middleware/edge_guard.rb for why the two are deliberately one switch.
class EdgeGuardTest < ActiveSupport::TestCase
  SECRET = "edge-secret-value"
  ROUTER = "10.1.2.3"          # the Heroku router: REMOTE_ADDR on every production request
  CF_EDGE = "172.68.1.1"       # inside 172.64.0.0/13, a published Cloudflare range
  CF_EDGE_V6 = "2606:4700:10::6816:1"
  STRANGER = "198.51.100.50"   # documentation range: nobody's edge

  # A request the way production sees one that came through our edge: the router's
  # private REMOTE_ADDR, with Cloudflare's address appended rightmost by the router.
  def through_edge(secret: SECRET, edge: CF_EDGE, client: "203.0.113.9", left: nil)
    chain = [left, client, edge].compact.join(", ")
    { "REMOTE_ADDR" => ROUTER, "HTTP_X_FORWARDED_FOR" => chain,
      "HTTP_CF_CONNECTING_IP" => client, "HTTP_X_EDGE_SECRET" => secret }.compact
  end

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

  # Both secret cases arrive from a genuine Cloudflare peer, so the range check passes and
  # the refusal can only come from the secret comparison. Cloudflare's ranges are shared by
  # every Cloudflare customer; against one of them the secret is the half doing the work.
  test "refuses a request presenting the wrong secret" do
    assert_equal 403, call(headers: through_edge(secret: "not-the-secret"))
    refute @downstream.called?
  end

  test "refuses a near-miss secret rather than accepting a prefix" do
    assert_equal 403, call(headers: through_edge(secret: SECRET[0..-2]))
    refute @downstream.called?
  end

  test "admits a request from a Cloudflare address bearing the shared edge secret" do
    assert_equal 200, call(headers: through_edge)
    assert @downstream.called?
  end

  test "admits an IPv6 Cloudflare edge address too" do
    assert_equal 200, call(headers: through_edge(edge: CF_EDGE_V6))
  end

  test "admits a request with no router in front when REMOTE_ADDR itself is Cloudflare" do
    assert_equal 200, call(headers: { "HTTP_X_EDGE_SECRET" => SECRET, "REMOTE_ADDR" => CF_EDGE })
  end

  # --- Armed: the secret alone is not the proof --------------------------------------
  # A leaked secret must not let anyone in from anywhere and name any client.

  test "refuses the right secret from an address outside Cloudflare's ranges" do
    assert_equal 403, call(headers: through_edge(edge: STRANGER))
    refute @downstream.called?, "a leaked secret alone must not buy entry"
  end

  test "refuses the right secret with no router-appended address at all" do
    assert_equal 403, call(headers: { "HTTP_X_EDGE_SECRET" => SECRET, "REMOTE_ADDR" => ROUTER })
    refute @downstream.called?
  end

  test "refuses a Cloudflare address written on the LEFT of X-Forwarded-For" do
    # The client wrote the Cloudflare address; the router appended the real peer.
    headers = { "REMOTE_ADDR" => ROUTER, "HTTP_X_FORWARDED_FOR" => "#{CF_EDGE}, #{STRANGER}",
                "HTTP_CF_CONNECTING_IP" => "1.2.3.4", "HTTP_X_EDGE_SECRET" => SECRET }
    assert_equal 403, call(headers: headers)
    refute @downstream.called?
  end

  test "a spoofed Forwarded header does not make a stranger look like Cloudflare" do
    headers = through_edge(edge: STRANGER).merge("HTTP_FORWARDED" => "for=#{CF_EDGE}")
    assert_equal 403, call(headers: headers)
  end

  test "refuses an unparseable peer address" do
    assert_equal 403, call(headers: through_edge(edge: "not-an-ip"))
  end

  test "cloudflare? knows the published ranges and nothing else" do
    assert EdgeGuard.cloudflare?(CF_EDGE)
    assert EdgeGuard.cloudflare?(CF_EDGE_V6)
    assert EdgeGuard.cloudflare?("104.16.0.1")
    refute EdgeGuard.cloudflare?(STRANGER)
    refute EdgeGuard.cloudflare?(ROUTER)
    refute EdgeGuard.cloudflare?("::ffff:172.68.1.1"), "a v4-mapped v6 address is not matched across families"
    refute EdgeGuard.cloudflare?("")
    refute EdgeGuard.cloudflare?("garbage")
  end

  test "peer_address reads the router-appended entry, never a client-written one" do
    assert_equal CF_EDGE, EdgeGuard.peer_address(through_edge(left: "6.6.6.6"))
    assert_equal CF_EDGE, EdgeGuard.peer_address("REMOTE_ADDR" => CF_EDGE, "HTTP_X_FORWARDED_FOR" => STRANGER),
                 "a public REMOTE_ADDR is the peer itself; X-Forwarded-For is client-written then"
  end

  test "keeps the platform health check reachable without the edge" do
    assert_equal 200, call(path: "/up")
    assert @downstream.called?, "refusing /up would fail Heroku health checks, not attackers"
  end

  # --- Armed: the real visitor IP --------------------------------------------------

  test "promotes the Cloudflare client IP so throttles see the visitor" do
    call(headers: through_edge(left: "6.6.6.6"))

    assert_equal "203.0.113.9", @downstream.env["REMOTE_ADDR"]
    assert_equal "203.0.113.9", @downstream.env["HTTP_X_FORWARDED_FOR"],
                 "Rack::Request#ip reads X-Forwarded-For, which is what rack-attack throttles on"
  end

  test "clears a memoized remote_ip so no stale edge address survives" do
    call(headers: through_edge.merge("action_dispatch.remote_ip" => CF_EDGE))

    assert_nil @downstream.env["action_dispatch.remote_ip"]
  end

  test "leaves the address alone when the edge sends no client IP" do
    call(headers: { "HTTP_X_EDGE_SECRET" => SECRET, "REMOTE_ADDR" => CF_EDGE })

    assert_equal CF_EDGE, @downstream.env["REMOTE_ADDR"]
  end

  # The whole reason lockdown and IP-trust share one switch: a forged CF-Connecting-IP
  # must never be believed, and the only evidence that it is genuine is the secret.
  test "ignores a forged client IP on a request that fails the edge proof" do
    call(headers: { "HTTP_CF_CONNECTING_IP" => "1.2.3.4" })

    refute @downstream.called?, "spoofed edge headers must not buy entry"
  end
end

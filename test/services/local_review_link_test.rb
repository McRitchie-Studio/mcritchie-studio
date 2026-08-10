# frozen_string_literal: true

require "test_helper"

# [unit] Where the WAITING APPROVAL button sends the reviewer.
#
# The bug this replaces: the board minted the magic link itself, so the operator
# landed signed into the BOARD's host (production) at the local page's path. The
# destination must therefore carry the local server's own origin — host AND port
# — and hand it the page to come back to.
#
# It must also carry NO user. The CTA is a public, sign-in-free redirect, so an
# email in this URL would be an address published on a public page — and with no
# signed-in visitor there is none to read anyway. The local desk names its own
# reviewer (studio-engine's Studio::LocalReviewsController, >= 0.36.0).
class LocalReviewLinkTest < ActiveSupport::TestCase
  test "[unit] builds the local server's own mint URL, port and all" do
    url = LocalReviewLink.for(local_url: "http://localhost:3111/admin/style")
    uri = URI.parse(url)

    assert_equal "localhost", uri.host
    assert_equal 3111, uri.port, "the demo's PORT is the whole point — one board, many local stacks"
    assert_equal "/_studio/local_review", uri.path

    query = Rack::Utils.parse_query(uri.query)
    assert_equal "/admin/style", query["return_to"], "the page under review must ride along"
  end

  # The property, asserted as a property rather than as "the email key is
  # absent": NOTHING in this URL may look like an address, whatever it is named.
  # A rename of the parameter must not quietly restore the leak.
  test "[unit] the URL carries no email address at all" do
    url = LocalReviewLink.for(local_url: "http://localhost:3111/admin/style")

    refute_match(/@/, url, "an address on a public redirect is the leak this avoids")
    assert_equal ["return_to"], Rack::Utils.parse_query(URI.parse(url).query).keys,
      "return_to is the only thing the board has any business sending"
  end

  test "[unit] a demo URL's query survives into return_to" do
    url = LocalReviewLink.for(local_url: "http://127.0.0.1:3026/tasks?stage=submitted")

    assert_equal "/tasks?stage=submitted", Rack::Utils.parse_query(URI.parse(url).query)["return_to"]
  end

  test "[unit] a bare origin returns to the root path" do
    url = LocalReviewLink.for(local_url: "http://localhost:3026")

    assert_equal "/", Rack::Utils.parse_query(URI.parse(url).query)["return_to"]
  end

  # --- loopback only ---------------------------------------------------------

  test "[unit] refuses a non-loopback host" do
    # An UNAUTHENTICATED public GET follows this URL, so the destination must be
    # a server on this machine — never wherever a local_url happens to point.
    # Opening the CTA up makes this the load-bearing guard, not a nicety.
    assert_nil LocalReviewLink.for(local_url: "https://qa.mcritchie.studio/admin/style")
    assert_nil LocalReviewLink.for(local_url: "http://evil.test/admin/style")
    assert_nil LocalReviewLink.for(local_url: "http://localhost.evil.test/x")
  end

  test "[unit] refuses a blank, non-HTTP, or unparseable URL" do
    assert_nil LocalReviewLink.for(local_url: nil)
    assert_nil LocalReviewLink.for(local_url: "")
    assert_nil LocalReviewLink.for(local_url: "/admin/style")
    assert_nil LocalReviewLink.for(local_url: "mailto:someone@example.com")
    assert_nil LocalReviewLink.for(local_url: "http://local host:3000/x")
  end

  test "[unit] 127.0.0.1 and ::1 are loopback too" do
    assert LocalReviewLink.for(local_url: "http://127.0.0.1:3026/tasks").present?
    assert LocalReviewLink.for(local_url: "http://[::1]:3026/tasks").present?
  end
end

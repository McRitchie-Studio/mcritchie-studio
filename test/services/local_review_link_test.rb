# frozen_string_literal: true

require "test_helper"

# [unit] Where the WAITING APPROVAL button sends the operator.
#
# The bug this replaces: the board minted the magic link itself, so the operator
# landed signed into the BOARD's host (production) at the local page's path. The
# destination must therefore carry the local server's own origin — host AND port
# — and hand it the page to come back to.
class LocalReviewLinkTest < ActiveSupport::TestCase
  EMAIL = "amcritchie@gmail.com"

  test "[unit] builds the local server's own mint URL, port and all" do
    url = LocalReviewLink.for(local_url: "http://localhost:3111/admin/style", email: EMAIL)
    uri = URI.parse(url)

    assert_equal "localhost", uri.host
    assert_equal 3111, uri.port, "the demo's PORT is the whole point — one board, many local stacks"
    assert_equal "/_studio/local_review", uri.path

    query = Rack::Utils.parse_query(uri.query)
    assert_equal EMAIL, query["email"]
    assert_equal "/admin/style", query["return_to"], "the page under review must ride along"
  end

  test "[unit] a demo URL's query survives into return_to" do
    url = LocalReviewLink.for(local_url: "http://127.0.0.1:3026/tasks?stage=submitted", email: EMAIL)

    assert_equal "/tasks?stage=submitted", Rack::Utils.parse_query(URI.parse(url).query)["return_to"]
  end

  test "[unit] a bare origin returns to the root path" do
    url = LocalReviewLink.for(local_url: "http://localhost:3026", email: EMAIL)

    assert_equal "/", Rack::Utils.parse_query(URI.parse(url).query)["return_to"]
  end

  # --- loopback only ---------------------------------------------------------

  test "[unit] refuses a non-loopback host" do
    # The operator's email rides in this URL and an admin session follows it, so
    # the destination must be a server on this machine — never wherever a
    # local_url happens to point.
    assert_nil LocalReviewLink.for(local_url: "https://qa.mcritchie.studio/admin/style", email: EMAIL)
    assert_nil LocalReviewLink.for(local_url: "http://evil.test/admin/style", email: EMAIL)
    assert_nil LocalReviewLink.for(local_url: "http://localhost.evil.test/x", email: EMAIL)
  end

  test "[unit] refuses a blank, non-HTTP, or unparseable URL" do
    assert_nil LocalReviewLink.for(local_url: nil, email: EMAIL)
    assert_nil LocalReviewLink.for(local_url: "", email: EMAIL)
    assert_nil LocalReviewLink.for(local_url: "/admin/style", email: EMAIL)
    assert_nil LocalReviewLink.for(local_url: "mailto:someone@example.com", email: EMAIL)
    assert_nil LocalReviewLink.for(local_url: "http://local host:3000/x", email: EMAIL)
  end

  test "[unit] 127.0.0.1 and ::1 are loopback too" do
    assert LocalReviewLink.for(local_url: "http://127.0.0.1:3026/tasks", email: EMAIL).present?
    assert LocalReviewLink.for(local_url: "http://[::1]:3026/tasks", email: EMAIL).present?
  end
end

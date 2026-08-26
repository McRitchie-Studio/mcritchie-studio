# frozen_string_literal: true

# Standalone coverage for bin/lib/review_hop.rb — the per-leg judgment behind
# bin/verify-review-hop.
#
# Run directly: `ruby -Itest test/lib/review_hop_test.rb`.
# Also picked up by the normal `bin/rails test` sweep.
#
# The point of every test below is the SAME point: each failure mode is
# success-shaped. A dead-ended CTA is a 302. A mint with no reviewer is a 302.
# A reviewer who is not an admin lands 200. So each case asserts that reading
# the DESTINATION separates them, because reading the status cannot.

require "minitest/autorun"
require_relative "../../bin/lib/review_hop"

class ReviewHopTest < Minitest::Test
  MINT = "http://localhost:3016/_studio/local_review?return_to=%2Fadmin%2Fstyle"

  # [unit] the CTA handing off to a loopback mint URL is the only pass
  def test_cta_passes_on_loopback_mint_url
    v = ReviewHop.cta(status: 302, location: MINT)

    assert v.ok?, v.detail
    assert_equal :cta_ok, v.code
  end

  # [unit] a blank / non-loopback local_url bounces to the task page — still a 302
  def test_cta_fails_when_it_bounces_back_to_the_task_page
    v = ReviewHop.cta(status: 302, location: "http://localhost:3016/tasks/some-slug")

    refute v.ok?
    assert_equal :cta_dead_end, v.code
    assert_match(/local_url/, v.detail)
  end

  # [unit] a mint URL pointing off-box is refused even though the path is right
  def test_cta_fails_on_non_loopback_mint_host
    v = ReviewHop.cta(status: 302, location: "https://qa.mcritchie.studio/_studio/local_review")

    refute v.ok?
    assert_equal :cta_off_box, v.code
  end

  # [unit] `/tasks/:slug/local-review` (hyphen) is a 404 — the route is local_review
  def test_cta_fails_on_non_redirect
    v = ReviewHop.cta(status: 404, location: nil)

    refute v.ok?
    assert_equal :cta_not_redirect, v.code
  end

  # [unit] the mint hands back a consumable token path
  def test_mint_passes_on_token_path
    v = ReviewHop.mint(status: 302, location: "http://localhost:3016/l/abc123")

    assert v.ok?, v.detail
    assert_equal :mint_ok, v.code
  end

  # [unit] MISSING_EMAIL: no reviewer resolves, engine redirects to the sign-in page.
  # This is the case the old chained-curl recipe degraded into a `/signin 200` pass.
  # [unit] the OTHER magic-link shape is consumable too.
  #
  # turf-monster overrides the engine's Studio::LinksController with its own
  # (inheriting ::MagicLinksController) so account creation stays on its single
  # audited, GATED path. Both /l/:token and /magic_link/:token route there, and
  # its local-review mint answers the latter. Verified against a live stack
  # 2026-08-26: both return 200 and render the same confirm interstitial.
  #
  # Before this, the checker reported that WORKING hop as BROKEN — a false
  # negative on the very gate building-sop Step 4 requires green before a task
  # may be marked waiting-for-approval.
  def test_mint_passes_on_the_app_local_magic_link_path
    v = ReviewHop.mint(status: 302, location: "http://localhost:3115/magic_link/abc123")

    assert v.ok?, "a /magic_link/<token> mint is a working hop, not a broken one: #{v.detail}"
    assert_equal :mint_ok, v.code
  end

  # [unit] widening the shape must not widen it to ANYTHING. A mint that lands
  # somewhere else entirely is still the failure this leg exists to catch.
  def test_mint_still_fails_on_an_unrelated_path
    v = ReviewHop.mint(status: 302, location: "http://localhost:3115/contests/world-cup")

    refute v.ok?, "an unrelated path must still fail — accepting two shapes is not accepting all"
    assert_equal :mint_unexpected, v.code
    assert_includes v.detail, "/magic_link/<token>",
                    "the failure should name BOTH accepted shapes so the reader knows the set"
  end

  def test_mint_fails_when_no_reviewer_resolves
    ReviewHop::SIGN_IN_PATHS.each do |path|
      v = ReviewHop.mint(status: 302, location: "http://localhost:3016#{path}")

      refute v.ok?, "#{path} should not count as a mint"
      assert_equal :mint_no_reviewer, v.code
      # The commonest cause in THIS ecosystem is an app below the engine floor
      # (turf-monster is on 0.31.0), so the verdict must name it and the way out.
      assert_match(/0\.36\.0/, v.detail)
      assert_match(/--email/, v.detail)
    end
  end

  # [unit] the confirm page must actually carry the CSRF token the consume needs
  def test_confirm_requires_a_csrf_token
    body = %(<form><input name="authenticity_token" value="tok-42" /></form>)

    assert ReviewHop.confirm(status: 200, body: body).ok?
    refute ReviewHop.confirm(status: 200, body: "<p>nope</p>").ok?
    assert_equal :confirm_no_csrf, ReviewHop.confirm(status: 200, body: "<p>nope</p>").code
    assert_equal :confirm_not_ok, ReviewHop.confirm(status: 404, body: body).code
  end

  # [unit] the consume must redirect onward, not render
  def test_consume_requires_a_redirect
    assert ReviewHop.consume(status: 302, location: "http://localhost:3016/admin/style").ok?
    refute ReviewHop.consume(status: 200, location: nil).ok?
    assert_equal :consume_no_location, ReviewHop.consume(status: 302, location: "").code
  end

  # [unit] landing ON the page under review is the only pass
  def test_landing_passes_on_the_expected_path
    v = ReviewHop.landing(status: 200, url: "http://localhost:3016/admin/style", expected_path: "/admin/style")

    assert v.ok?, v.detail
  end

  # [unit] THE quiet failure: sign-in succeeded, require_admin bounced to "/", 200.
  # Still reachable at studio-engine 0.38.0 — provision_reviewer rescues and lets
  # the mint proceed, so a host whose User validation rejects the reviewer lands here.
  def test_landing_on_root_is_the_not_an_admin_failure
    v = ReviewHop.landing(status: 200, url: "http://localhost:3016/", expected_path: "/admin/style")

    refute v.ok?
    assert_equal :landing_not_authorized, v.code
    assert_match(/not an admin/, v.detail)
  end

  # [unit] a sign-in page at the end means the session never took
  def test_landing_on_sign_in_is_reported_as_such
    v = ReviewHop.landing(status: 200, url: "http://localhost:3016/signin", expected_path: "/admin/style")

    refute v.ok?
    assert_equal :landing_not_signed_in, v.code
  end

  # [unit] a 200 on the WRONG page is still a failure
  def test_landing_on_a_different_page_fails
    v = ReviewHop.landing(status: 200, url: "http://localhost:3016/tasks", expected_path: "/admin/style")

    refute v.ok?
    assert_equal :landing_wrong_page, v.code
  end

  # [unit] a multi-param review URL survives: the expectation is the FULL query,
  # where a hand-typed `return_to=%2F<path>` truncates at the first `&`
  def test_expected_return_path_keeps_the_whole_query
    mint = "http://localhost:3016/_studio/local_review?return_to=%2Ftasks%3Fstage%3Dbuilding%26agent%3Davi"

    assert_equal "/tasks?stage=building&agent=avi", ReviewHop.expected_return_path(mint)
  end

  # [unit] a mint URL with no return_to lands on "/"
  def test_expected_return_path_defaults_to_root
    assert_equal "/", ReviewHop.expected_return_path("http://localhost:3016/_studio/local_review")
  end

  # [unit] loopback set matches LocalReviewLink's
  def test_loopback_hosts
    assert ReviewHop.loopback?("LOCALHOST")
    assert ReviewHop.loopback?("127.0.0.1")
    refute ReviewHop.loopback?("qa.mcritchie.studio")
  end
end

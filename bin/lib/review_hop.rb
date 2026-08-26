# frozen_string_literal: true

require "uri"

# The judgment behind `bin/verify-review-hop`: given what one leg of the local
# review hop ANSWERED, decide whether that leg actually worked.
#
# Why this is a module and not five inline `if`s in the script: every failure
# mode named below returns a SUCCESS-SHAPED response, so the two checks an agent
# reaches for by reflex — "did it 302?" and "did it end 200?" — are both blind.
# Measured against a live stack on 2026-08-11:
#
#   * The board CTA answers 302 whether it hands over a mint URL or bounces
#     straight back to the task page. A blank local_url, a QA host, a wrong
#     port — LocalReviewLink.for returns nil for all three and the action
#     redirects to /tasks/<slug>. Status: 302. Follow it: 200.
#   * A mint with no resolvable reviewer answers 302 to /login (the engine's
#     MISSING_EMAIL). Scraping that page for a CSRF token finds none, POSTing
#     nothing to it still redirects, and the run finishes on `/signin 200`.
#
# So both blind checks report a healthy hop over a hop that never happened. The
# verdicts here read the DESTINATION instead, which is the only thing that
# separates arriving on the page under review from dead-ending somewhere
# perfectly healthy.
module ReviewHop
  # studio-engine's dev-only mint endpoint (Studio::LocalReviewsController).
  MINT_PATH = "/_studio/local_review"

  # Mirrors LocalReviewLink::LOOPBACK_HOSTS. The CTA refuses to bounce a public
  # visitor off-box, so a mint URL that is not loopback did not come from it.
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 0.0.0.0 ::1 [::1]].freeze

  # Where a failed sign-in comes to rest. Both spellings are real: the engine
  # redirects to login_path when it cannot resolve a reviewer, and the hub's
  # own /login redirects on to /signin.
  SIGN_IN_PATHS = %w[/login /signin].freeze

  # The consumable magic-link paths the mint may hand back — BOTH entry points
  # in this ecosystem, not just the engine's `/l/<token>`. The set is CLOSED AT
  # TWO by construction: studio-engine picks between them with a binary switch
  # (`Studio.magic_link_via_l_route?`, app/controllers/concerns/studio/
  # magic_link_issuing.rb), and turf-monster's override mints the other shape.
  # Same short Studio::Link token either way; only the prefix differs.
  #
  # This used to be /l/ alone, and it reported a WORKING hop as BROKEN for
  # turf-monster: that app overrides the engine's Studio::LinksController with
  # its own (inheriting ::MagicLinksController) so account creation stays on its
  # single audited, GATED path — the engine's generic sign_up_new must never run
  # there. Both routes exist and both funnel through that same gated controller,
  # so its local-review mint answers /magic_link/<token>. Verified against a live
  # stack 2026-08-26: /l/<token> and /magic_link/<token> BOTH return 200 and both
  # render the same confirm interstitial.
  #
  # WHY THIS MATTERED MORE THAN THE SPELLING: building-sop Step 4 says "do not
  # mark a task waiting-for-approval without a green run". A false negative on a
  # gate does not just annoy — it blocks the honest builder and teaches everyone
  # else to ignore the gate, which is the disease the gate was built to cure.
  #
  # Legs 3 and 4 follow whatever path the mint returned (verify-review-hop builds
  # token_url from the mint's own Location), so widening this does not hardcode a
  # second assumption anywhere downstream.
  TOKEN_PATH = %r{\A/(?:l|magic_link)/[^/]+\z}.freeze

  Verdict = Struct.new(:ok, :code, :detail, keyword_init: true) do
    def ok? = ok
  end

  class << self
    def pass(code, detail) = Verdict.new(ok: true, code: code, detail: detail)
    def fail(code, detail) = Verdict.new(ok: false, code: code, detail: detail)

    def loopback?(host)
      LOOPBACK_HOSTS.include?(host.to_s.downcase)
    end

    # LEG 1 — the board's WAITING APPROVAL CTA (GET /tasks/:slug/local_review).
    #
    # The leg that historically broke, and the one a hand-written curl recipe
    # skips because it starts at the local mint. Note the route spelling:
    # local_review with an UNDERSCORE. `/tasks/:slug/local-review` is a 404, and
    # a 404 here is indistinguishable from "task not found" if you are only
    # reading status codes.
    def cta(status:, location:)
      return fail(:cta_not_redirect, "expected a 302 from the CTA, got #{status}") unless redirect?(status)
      return fail(:cta_no_location, "CTA answered #{status} with no Location header") if location.to_s.empty?

      uri = parse(location)
      return fail(:cta_bad_location, "CTA Location is not a URL: #{location}") if uri.nil?

      if uri.path == MINT_PATH && loopback?(uri.host)
        pass(:cta_ok, "CTA handed off to #{location}")
      elsif uri.path == MINT_PATH
        fail(:cta_off_box, "CTA pointed at a NON-loopback mint host (#{uri.host}) — refuse this link")
      else
        # The dead end: LocalReviewLink.for returned nil, so the action bounced
        # back to the task page with an alert nobody reads in a curl.
        fail(:cta_dead_end,
             "CTA bounced back to #{uri.path} instead of #{MINT_PATH} — the task's local_url is " \
             "blank, unparseable, or not a loopback URL, so the button dead-ends")
      end
    end

    # LEG 2 — the local mint (GET /_studio/local_review?return_to=<path>).
    #
    # Deliberately NO ?email=. The live CTA sends none, and passing one
    # short-circuits `params[:email].presence || Studio.local_review_email ||
    # seeded_admin_email` at priority 1 — verifying a chain the button never
    # walks, as a user the button would never pick.
    def mint(status:, location:)
      return fail(:mint_not_redirect, "expected a 302 from the mint, got #{status}") unless redirect?(status)

      uri = parse(location)
      return fail(:mint_bad_location, "mint Location is not a URL: #{location}") if uri.nil?

      if uri.path.match?(TOKEN_PATH)
        pass(:mint_ok, "minted #{uri.path}")
      elsif SIGN_IN_PATHS.include?(uri.path)
        fail(:mint_no_reviewer,
             "mint redirected to #{uri.path} — this desk resolved NO reviewer " \
             "(studio-engine's MISSING_EMAIL). Either this app is on studio-engine < 0.36.0, " \
             "which has no reviewer fallback and REQUIRES an address (re-run with " \
             "--email <an admin in THIS app>), or set Studio.local_review_email / seed an admin")
      else
        fail(:mint_unexpected, "mint redirected to #{uri.path}, expected /l/<token> or /magic_link/<token>")
      end
    end

    # LEG 3 — the confirm page (GET /l/<token>), which carries the CSRF token
    # the consume POST needs. No token means the previous leg handed us a page
    # that is not the confirm page, whatever its status was.
    def confirm(status:, body:)
      return fail(:confirm_not_ok, "confirm page answered #{status}, expected 200") unless status.to_i == 200

      token = csrf_token(body)
      return fail(:confirm_no_csrf, "no authenticity_token on the confirm page — this is not the magic-link page") if token.nil?

      pass(:confirm_ok, "confirm page carries a CSRF token")
    end

    # LEG 4 — the consume (POST /l/<token>).
    #
    # POST and then follow the Location BY HAND. `curl -L -X POST` replays the
    # forced method across the redirect and 404s on the review path, which reads
    # like a broken page rather than a broken recipe.
    def consume(status:, location:)
      return fail(:consume_not_redirect, "consume answered #{status}, expected a 302") unless redirect?(status)
      return fail(:consume_no_location, "consume answered #{status} with no Location") if location.to_s.empty?

      pass(:consume_ok, "consumed, redirecting to #{location}")
    end

    # LEG 5 — the landing. The whole point: did the operator arrive ON the page
    # under review, signed in?
    #
    # `/` is the quiet failure this endpoint's provisioning exists to prevent —
    # sign-in SUCCEEDED and `require_admin` bounced the reviewer. Still possible
    # at studio-engine 0.38.0: provision_reviewer rescues StandardError and lets
    # the mint proceed, so a host with an extra User validation logs a warning
    # and lands here anyway. The engine's own comment is the rule — provisioning
    # "is the thing that makes it pass, not the thing that proves it".
    def landing(status:, url:, expected_path:)
      uri = parse(url)
      return fail(:landing_bad_url, "landing URL is not a URL: #{url}") if uri.nil?

      actual = path_with_query(uri)
      if status.to_i != 200
        fail(:landing_not_ok, "landed on #{actual} with #{status}, expected 200")
      elsif actual == expected_path
        pass(:landing_ok, "landed on #{actual} with 200")
      elsif uri.path == "/"
        fail(:landing_not_authorized,
             "landed on / with 200 — the sign-in SUCCEEDED and the reviewer is not an admin. " \
             "Provisioning did not take; check the desk's log for a provision warning")
      elsif SIGN_IN_PATHS.include?(uri.path)
        fail(:landing_not_signed_in, "landed on #{uri.path} — the sign-in did not take")
      else
        fail(:landing_wrong_page, "landed on #{actual}, expected #{expected_path}")
      end
    end

    # The path the hop must finish on, read off the mint URL the CTA built. Read
    # from `return_to` rather than from the task's local_url so the assertion is
    # against what the BUTTON asked for; a full multi-param query survives here,
    # where a hand-typed `return_to=%2F<path>` truncates at the first `&`.
    def expected_return_path(mint_url)
      uri = parse(mint_url)
      return nil if uri.nil?

      value = URI.decode_www_form(uri.query.to_s).to_h["return_to"]
      value.to_s.empty? ? "/" : value
    end

    def csrf_token(body)
      body.to_s[/name="authenticity_token"[^>]*value="([^"]+)"/, 1]
    end

    def path_with_query(uri)
      path = uri.path.to_s.empty? ? "/" : uri.path
      uri.query.to_s.empty? ? path : "#{path}?#{uri.query}"
    end

    def redirect?(status)
      (300..399).cover?(status.to_i)
    end

    def parse(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTP) ? uri : nil
    rescue URI::InvalidURIError
      nil
    end
  end
end

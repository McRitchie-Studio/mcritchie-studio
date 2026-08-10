# frozen_string_literal: true

# Where the board's WAITING APPROVAL button has to send the operator.
#
# A magic link signs you into the app that MINTED it — the token lives in that
# app's store, and Studio::LinkToken.sanitize_path keeps `return_to` a
# same-origin PATH. So a link minted HERE, on the board, can only ever land the
# operator on the BOARD's host: click "review this locally" on
# https://mcritchie.studio and you arrive, signed in, on
# https://mcritchie.studio/admin/style. The path was right and the server was
# wrong — the exact bug this class exists to end.
#
# The only server that can create a session on the local stack is the local
# stack. So the board stops minting and hands off: it builds the local server's
# own mint URL (studio-engine's dev-only Studio::LocalReviewsController) from the
# task's local_url, and redirects there. That endpoint mints in ITS database and
# lands the reviewer signed-in on the page under review.
#
# The URL it builds carries ONE parameter — the return path. It names no user:
# the CTA is a public, sign-in-free redirect, so an email here would be an
# address published on a public page. The local desk knows its own operator
# (Studio.local_review_email, else its first admin — studio-engine >= 0.36.0).
class LocalReviewLink
  MINT_PATH = "/_studio/local_review"

  # Loopback only. This URL is reached by an UNAUTHENTICATED public GET (the
  # board's WAITING APPROVAL CTA), so the destination must be a server on this
  # machine, never wherever a local_url happens to point. A local_url that is not
  # loopback (a QA host, a typo, anything public) yields nil and the caller falls
  # back to the task page rather than bouncing a visitor off-box.
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 0.0.0.0 ::1 [::1]].freeze

  class << self
    # nil when local_url is blank, unparseable, or not a loopback host.
    #
    # No email rides along, by design. The CTA is public, so an address here
    # would be published on a public page; and there is no signed-in user to
    # read one from. The LOCAL stack names its own reviewer instead
    # (Studio.local_review_email, else its first admin — studio-engine >= 0.36.0).
    def for(local_url:)
      uri = parse(local_url)
      return nil if uri.nil?

      mint = uri.dup
      mint.path = MINT_PATH
      mint.query = URI.encode_www_form({ return_to: return_path(uri) }.compact_blank)
      mint.fragment = nil
      mint.to_s
    end

    # The page under review, as the same-origin path the mint endpoint will hand
    # back to the sign-in link. Query survives (a demo URL may be filtered);
    # the host does not — it is the local server's own origin by then.
    def return_path(uri)
      path = uri.path.presence || "/"
      uri.query.present? ? "#{path}?#{uri.query}" : path
    end

    private

    def parse(local_url)
      uri = URI.parse(local_url.to_s)
      return nil unless uri.is_a?(URI::HTTP) # HTTP(S) only — no mailto:, no file:
      return nil unless LOOPBACK_HOSTS.include?(uri.host.to_s.downcase)

      uri
    rescue URI::InvalidURIError
      nil
    end
  end
end

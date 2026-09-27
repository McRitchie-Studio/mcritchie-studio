require "net/http"
require "json"

module Espn
  # HOW THIS APP TALKS TO ESPN — the host it dials, the name it gives, and the
  # transport failures it expects. ONE copy, because two copies is the bug this
  # module was extracted to end.
  #
  # ── THE HOST, AND WHY IT IS NOT THE OBVIOUS ONE ──────────────────────────────
  #
  # Both site.api.espn.com and site.web.api.espn.com serve
  # `/apis/site/v2/sports/football/nfl/...`, and the documents are the same. But
  # site.api.espn.com sits behind a WAF that filters on User-Agent, and Ruby does
  # not get through it. Measured 2026-09-27 from Net::HTTP, not from a terminal:
  #
  #     UA                              site.api           site.web.api
  #     "Ruby" (Net::HTTP's default)    403 /   437 bytes  200 / 148848 bytes
  #     "" (empty string)               403 /   437 bytes  200 / 148848 bytes
  #     mcritchie-studio/1.0            403 /   437 bytes  200 / 148848 bytes
  #     a Chrome 120 browser string     403 /   437 bytes  200 / 148848 bytes
  #     curl/8.7.1 (from the shell)     200 / 148848 bytes 200 / 148848 bytes
  #
  # READ THE FIRST ROW'S LABEL LITERALLY. A request whose User-Agent is never set
  # does not arrive without one: measured on the wire, Net::HTTP fills in
  # `User-Agent: Ruby`. That is why the table carries a "Ruby" row and no "(none)"
  # row — an earlier draft labelled that same request "(none)", and the mislabel was
  # the error, not a missing measurement.
  #
  # A GENUINELY UA-LESS REQUEST IS REACHABLE, and it is one line: `req["User-Agent"]
  # = nil` DELETES the header, where `= ""` sends `User-Agent:` with nothing after
  # it. Measured 2026-09-27, on a local socket and then against ESPN: site.web.api
  # answers that headerless request 200 / 148848 bytes, the same as every row above.
  # So this host does not merely tolerate our UA, it does not consult one at all,
  # which is why an honest string costs nothing here. The site.api cell of that row
  # was not measured and is deliberately absent rather than guessed.
  #
  # The 403 body is an Akamai "Access Denied" page, so it is not even JSON: a
  # caller that parses before checking the status raises, and one that returns nil
  # on any non-success reports "ESPN has nothing" about a service it never reached.
  #
  # NOTE THE CHROME ROW. The WAF rejects the BROWSER string and admits curl, so the
  # usual impersonation reflex makes this strictly worse. The fix is to ask the host
  # that does not filter, not to dress Ruby up as something it is not.
  #
  # THIS IS THE MOST DANGEROUS SHAPE A BUG CAN TAKE, because of HOW it lies:
  # `curl https://site.api.espn.com/...` answers 200 from a terminal, so
  # hand-verifying the endpoint PROVES it works, and then the identical request
  # from the application 403s because the application is Ruby. A verification that
  # cannot reproduce the failure is what kept this host in two services at once.
  #
  # ── WHY IT LIVES HERE AND NOT IN EACH SERVICE ────────────────────────────────
  #
  # Espn::PlayerProfile carried the working host and an honest UA while
  # Espn::ScrapeDepthCharts, in the same directory, carried the dead host and a
  # Chrome string — and the scraper was dead for as long as that divergence lasted.
  # A second copy of a host is a second place for this to rot, so both services
  # read these constants and neither spells a host out again.
  #
  # THE THIRD COPY IS NOW REPAIRED, under `revive-coaches-seed-host`:
  # lib/tasks/nfl.rake's `nfl:link_coach_headshots` named site.api.espn.com and
  # read it with `URI.open`. It now resolves WEB_HOST and USER_AGENT from here, so no
  # ESPN *API* host is spelled out in that lane, and a test refuses these three back
  # into that file. NOT "no host at all": a.espncdn.com, the headshot CDN, is still
  # spelled out there in nfl:upload_headshots's operator message, and is deliberately
  # NOT guarded — it is not an Espn::Api constant and it never filtered.
  # MEASURED 2026-09-27 through open-uri itself — the call that task makes —
  # with this host carried as a control: site.api answered 403 Forbidden / 437
  # bytes and site.web.api answered 200 / 148848, for both the open-uri default UA
  # and the honest one above. The user agent moved neither host; only the host did.
  #
  # TWO CORRECTIONS TO WHAT THIS NOTE USED TO SAY, both measured while repairing it:
  #
  #   * It described that task's rescue shape as "OpenURI::HTTPError into a per-team
  #     `rescue StandardError`". The per-team rescue is real, but the INDEX fetch sat
  #     ABOVE the loop and was not covered by it, so the 403 propagated out of the
  #     task as a bare open-uri backtrace. It now aborts naming the host trap.
  #   * It pinned the task at :431 and the constant at :426. Those were CORRECT at
  #     fb95c5af, where this note was written, and went stale the same day when PR
  #     1685 added ~186 lines above them. Names are the durable handle; a line
  #     number in this file is only true for one commit.
  #
  # THAT TASK CANNOT SPELL THESE CONSTANTS THE WAY THIS FILE'S CONSUMERS DO, and the
  # difference is load order, not taste. Rails loads lib/tasks/*.rake BEFORE the
  # `:environment` task sets Zeitwerk up, so `Espn::Api` is not resolvable while a
  # .rake file's constant assignments run. MEASURED with a throwaway .rake file and
  # `rake -T`: an eager `ESPN_TEAMS_INDEX_URL = "https://#{Espn::Api::WEB_HOST}/..."`
  # there raises `NameError: uninitialized constant Espn` and drops the repository
  # from 165 loadable rake tasks to 0 — every task, not just that one, and the
  # listing dies rather than shrinking. RE-MEASURED at review both ways: with a
  # throwaway .rake file, and by eager-spelling the constant in nfl.rake itself.
  # (An earlier draft of this note said "to 1"; `rake -T` reports 0.) So the rake lane
  # holds callables that resolve these constants at run time. Copying the eager
  # spelling below into a .rake file is the one edit that looks like a tidy-up and
  # takes the whole task list down.
  module Api
    # THE HOST THAT SERVES RUBY. site.api.espn.com is the one that does not; see
    # the table above before changing this by one word.
    WEB_HOST = "site.web.api.espn.com".freeze

    # ESPN's core/v2 host, which never filtered. Measured 2026-09-27: 200 from
    # Net::HTTP for the depth chart document of all 32 team ids. Named here so both
    # halves of "where ESPN lives" are in one file, not so that it needs fixing.
    CORE_HOST = "sports.core.api.espn.com".freeze

    # The host that must never be dialled from Ruby. Kept as a constant so the
    # tests that refute it are refuting one spelling rather than a literal each.
    FILTERED_HOST = "site.api.espn.com".freeze

    # WHO WE SAY WE ARE. An honest identifier with a contact URL, because every
    # endpoint this app touches serves it and a third party should be able to see
    # who is calling. Impersonating a browser bought nothing and cost the roster
    # call outright.
    USER_AGENT = "mcritchie-studio/1.0 (+https://mcritchie.studio)".freeze

    # The failures that mean "the network, not ESPN's answer". JSON::ParserError
    # belongs here because a body that is not JSON is a transport-shaped lie about
    # the document — the 403 page above is exactly that.
    TRANSPORT_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED,
      Errno::ECONNRESET, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError, JSON::ParserError
    ].freeze
  end
end

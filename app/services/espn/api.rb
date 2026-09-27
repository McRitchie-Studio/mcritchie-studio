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
  #     (none)                          -                  200 / 148848 bytes
  #     mcritchie-studio/1.0            403 /   437 bytes  200 / 148848 bytes
  #     a Chrome 120 browser string     403 /   437 bytes  200 / 148848 bytes
  #     curl/8.7.1 (from the shell)     200 / 148848 bytes 200 / 148848 bytes
  #
  # The 403 body is an Akamai "Access Denied" page, so it is not even JSON: a
  # caller that parses before checking the status raises, and one that returns nil
  # on any non-success reports "ESPN has nothing" about a service it never reached.
  #
  # NOTE THE THIRD ROW. The WAF rejects the BROWSER string and admits curl, so the
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
  # A THIRD COPY IS STILL OUT THERE, deliberately not repaired here:
  # lib/tasks/nfl.rake's `nfl:coaches_seed` names site.api.espn.com and reads it
  # with URI.open, which sends Ruby's own default UA and therefore 403s the same
  # way. It is a different code path with a different rescue shape and its own
  # acceptance, it is under review in another PR as this lands, and it is filed
  # rather than smuggled in.
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

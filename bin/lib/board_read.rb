# frozen_string_literal: true

require "net/http"

# BoardRead — the STATUS posture for a board READ, and the single property it
# exists to hold: a read that FAILED never renders as a read that found nothing.
#
# ═══ WHY THIS IS ITS OWN MODULE AND NOT A METHOD ON TaskBoard ═══
#
# bin/lib/task_board.rb is deliberately POSTURE-FREE about status — `request`
# returns the raw response, and its strict body readers (`parse_body!`, `rows!`)
# refuse a body they cannot read WITHOUT ever consulting `res.code`. That is a
# documented invariant in its header, and it is the right one: the eleven board
# CLIs genuinely differ in how they fail, and a status check welded into the
# transport would decide for all of them.
#
# So TaskBoard owns the BODY question ("can I read this?") and this module owns the
# STATUS question ("may I treat this as an answer at all?"). They are complementary,
# not redundant: a 301 from Rails carries a perfectly well-formed HTML body, so no
# body reader can catch it, and a 200 carrying an error payload is caught by `rows!`
# and not by anything here.
#
# ═══ WHY IT RETURNS A MESSAGE INSTEAD OF RAISING ═══
#
# The caller owns its exit code — bin/review-autopilot documents three (0 done,
# 2 refused, 1 could not run) and the difference between the last two is the
# difference between "the tool declined" and "go look at the board". A helper that
# raised would take that choice away and hand the operator a backtrace.
#
# ═══ WHY THE MESSAGE SAYS MORE THAN THE CODE (2026-09-20) ═══
#
# bin/review-autopilot and bin/devops-cycle defaulted TASK_BOARD_URL to
# https://www.mcritchie.studio. lib/middleware/canonical_host.rb 301s that alias
# onto the apex; TaskBoard.request follows no 3xx. Every GET came back 301 while the
# POSTs — which the middleware does not redirect — landed normally, so writes worked
# and reads did not. The CLI printed `list failed -> HTTP 301` and I diagnosed an
# expired agent token, because once the code is the only thing on the line a 301
# looks exactly like a 401. A bare status code is not a diagnosis. 3xx names the
# redirect target and the env var that fixes it; 401/403 says the word the reader
# is already reaching for, so they stop reaching for it on every other code.
module BoardRead
  module_function

  # nil when +res+ is a response the caller may READ; otherwise the line to die on.
  #
  # +what+ names the read in the operator's own vocabulary ("list", "task <slug>"),
  # because "a read failed" is not actionable and "the task read failed" is.
  def refusal(res, what:)
    return nil if res.is_a?(Net::HTTPSuccess)

    "#{what} failed -> HTTP #{res.code}#{detail(res)}"
  end

  # The sentence that separates the three ways a board read fails. Net::HTTPSuccess,
  # Net::HTTPRedirection and the rest are MODULES mixed into the response classes,
  # so `case/when` matches them through Module#=== — i.e. the same `is_a?` test the
  # callers use, not a string compare on `res.code`.
  def detail(res)
    case res
    when Net::HTTPRedirection then redirect_detail(res)
    when Net::HTTPUnauthorized, Net::HTTPForbidden
      " — the board refused this agent's credential. This one IS the token, " \
        "not the host."
    else ""
    end
  end

  # A redirect is the case that masquerades as every other case, so it gets the
  # longest sentence: where it was sent, that nothing here will follow it, and the
  # one variable whose value caused it.
  def redirect_detail(res)
    target = res["location"].to_s
    where = target.empty? ? "" : " to #{target}"

    " (redirected#{where}). The board client does not follow redirects by design, " \
      "so this is a HOST problem and not a credential one: point TASK_BOARD_URL at " \
      "the canonical host."
  end
end

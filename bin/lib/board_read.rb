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
#
# ═══ TWO EVIDENCE SHAPES, ONE PROPERTY (2026-09-22) ═══
#
# `refusal` below takes a Net::HTTPResponse, so it can only serve a caller that
# made the request ITSELF. Half this house's board reads are taken through a CLI —
# bin/conductor shells `bin/task list --stage X`, bin/devops-reconcile shells
# `bin/review-autopilot list --all` — and those callers hold an exit status and a
# stderr stream, never a response object. The card that filed this work prescribed
# "route conductor's reads through BoardRead.refusal"; measured, that is not a
# thing conductor can do, and neither can any other shell-out caller.
#
# The PROPERTY is identical, so it stays in one module: a read that FAILED never
# renders as a read that found nothing. Only the evidence differs, so there are
# two entry points and no duplication of the rule.
#
# `shell_refusal` also carries the one distinction its HTTP sibling does not need:
# a child may exit non-zero to say the board ANSWERED, NEGATIVELY. `bin/task`
# exit 4 (EXIT_TASK_NOT_FOUND) means "the board positively answered: there is no
# such task" — that is an answer, and refusing it would turn an archived slug into
# an outage. `answered:` names those codes. Everything else is a failed read.

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

  # --- the subprocess half ---------------------------------------------------

  # nil when the CHILD's outcome means the caller may READ its stdout; otherwise
  # the line to die on. See the TWO EVIDENCE SHAPES note above.
  #
  # +status+ is a Process::Status, or nil when the command never ran at all
  # (Errno::ENOENT on a mis-resolved path, a fork failure). nil is a FAILED READ,
  # not an unknown: the caller asked the board a question and got nothing back,
  # which is the exact state this module refuses to render as an empty answer.
  #
  # +answered+ lists the exit codes on which the child is reporting the BOARD's
  # negative answer rather than its own failure (bin/task's 4 = task not found).
  def shell_refusal(status, stderr, what:, answered: [])
    return nil if status&.success?
    return nil if status && status.exitstatus && Array(answered).include?(status.exitstatus)

    "#{what} failed -> #{outcome(status)}#{child_detail(stderr)}"
  end

  # How the child ended, in the operator's vocabulary. A signalled child has a nil
  # exitstatus, so a bare `exit #{status.exitstatus}` would print "exit " and read
  # as a parse bug rather than as a kill.
  def outcome(status)
    return "the command never ran" if status.nil?
    return "exit #{status.exitstatus}" if status.exitstatus

    "killed by signal #{status.termsig}"
  end

  # THE CHILD'S OWN DIAGNOSIS, which is the whole reason this exists. Every board
  # CLI already dies with a sentence naming the host, the status or the credential
  # — bin/task's `api` die!s "GET /api/v1/tasks -> 301: …", bin/review-autopilot
  # prints the UNREADABLE line. A caller that captured stderr into `_err` and then
  # rendered an empty list threw away a finished diagnosis and substituted silence.
  #
  # An EMPTY stderr is itself a finding and is said out loud: a tool that died
  # without explaining is a different problem from one that explained.
  def child_detail(stderr)
    text = stderr.to_s.strip
    return " — and it said nothing on stderr, so the reason is not recoverable here" if text.empty?

    "\n  #{text.gsub("\n", "\n  ")}"
  end
end

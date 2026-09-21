# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require_relative "../../bin/lib/board_read"

# [unit] The STATUS decision under every board read: may this response be treated
# as an answer, and if not, what does the operator do about it?
#
# The companion integration file (test/commands/review_autopilot_test.rb) proves the
# EXIT CODE end to end through the real script. This one proves the decision itself,
# response class by response class, because the exit code is downstream of it and a
# subprocess test cannot enumerate the status space cheaply.
#
# THE CASE THAT CARRIES THIS FILE is `test_a_redirect_is_not_a_credential_failure`.
# On 2026-09-20 a 301 on every board GET was read as an expired agent token and
# chased into 1Password — the wrong system entirely — because "-> HTTP 301" and
# "-> HTTP 401" are the same sentence with a different number in it.
class BoardReadTest < Minitest::Test
  # ── the answers that may be read ───────────────────────────────────────────

  def test_a_success_is_no_refusal
    assert_nil BoardRead.refusal(response(Net::HTTPOK, "200"), what: "list")
  end

  # 204 is a Net::HTTPSuccess too, and a DELETE legitimately answers with one. If
  # this refused, `disarm` would report a failure on every successful run.
  def test_a_no_content_success_is_no_refusal
    assert_nil BoardRead.refusal(response(Net::HTTPNoContent, "204"), what: "disarm")
  end

  # ── the answers that may not ───────────────────────────────────────────────

  def test_a_server_error_refuses_and_names_the_read
    message = BoardRead.refusal(response(Net::HTTPInternalServerError, "500"), what: "task probe-slug")

    refute_nil message
    assert_includes message, "task probe-slug failed"
    assert_includes message, "HTTP 500"
  end

  # THE ONE THAT MATTERS. Not "does it refuse" — a bare code refuses too — but "does
  # the message send the reader to the right system".
  def test_a_redirect_is_not_a_credential_failure
    message = BoardRead.refusal(
      response(Net::HTTPMovedPermanently, "301",
               "location" => "https://mcritchie.studio/api/v1/review_pending_actions"),
      what: "list"
    )

    assert_includes message, "https://mcritchie.studio/api/v1/review_pending_actions",
                    "the redirect TARGET is the operator's fix; without it the code is a riddle"
    assert_includes message, "TASK_BOARD_URL"
    assert_match(/does not follow redirects/i, message)
    assert_match(/HOST problem/i, message)
  end

  # A redirect with no Location still refuses, and still says what kind of problem it
  # is. Degrading to a bare code here would reintroduce the whole defect for the one
  # case nobody tests by hand.
  def test_a_redirect_without_a_location_still_names_the_kind_of_problem
    message = BoardRead.refusal(response(Net::HTTPFound, "302"), what: "list")

    assert_includes message, "HTTP 302"
    assert_match(/does not follow redirects/i, message)
    refute_includes message, " to ", "no target was sent; inventing the phrasing for one is worse than omitting it"
  end

  def test_an_unauthorized_read_says_the_token
    message = BoardRead.refusal(response(Net::HTTPUnauthorized, "401"), what: "list")

    assert_match(/credential/i, message)
    refute_match(/redirect/i, message)
  end

  def test_a_forbidden_read_says_the_token_too
    assert_match(/credential/i, BoardRead.refusal(response(Net::HTTPForbidden, "403"), what: "list"))
  end

  # The complement of the 401 case, and the reason `detail` has an `else` branch: a
  # 500 must NOT accuse the credential. Suspecting the token on every failure is the
  # habit this module exists to break, so blanket-accusing it would be the same bug
  # with a longer message.
  def test_a_server_error_does_not_accuse_the_credential
    message = BoardRead.refusal(response(Net::HTTPInternalServerError, "500"), what: "list")

    refute_match(/credential/i, message)
    refute_match(/redirect/i, message)
  end

  private

  # A real Net::HTTPResponse subclass, instantiated the way Net::HTTP does. Using the
  # genuine classes is load-bearing: `refusal` and `detail` branch on the MODULES
  # (Net::HTTPSuccess, Net::HTTPRedirection) that Ruby mixes into them, so a double
  # answering `code` and `[]` would pass every case here while the real 301 — the one
  # that started this — fell through to the empty `else`.
  def response(klass, code, headers = {})
    res = klass.new("1.1", code, "stub")
    headers.each { |key, value| res[key] = value }
    res
  end
end

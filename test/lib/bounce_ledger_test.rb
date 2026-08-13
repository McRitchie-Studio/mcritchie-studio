# frozen_string_literal: true

# [unit] BounceLedger — the two-bounce circuit breaker's read.
#
# THE DEFECT THIS FILE PINS (2026-08-13, /tasks/circuit-breaker-check-always-zero).
# The review SOPs used to hand every agent a prose recipe — "GET
# /api/v1/activities?...&activity_type=qa_feedback, count the rows" — and the
# hand-rolled form counted rows on the Net::HTTPResponse OBJECT. Net::HTTPResponse#[]
# is the HTTP HEADER reader, so `response["data"]` is nil, `Array(nil)` is `[]`, and
# the breaker reported ZERO PRIOR BOUNCES for every task on earth. Silently. With an
# answer that looks exactly like the good news the caller wanted.
#
# WHAT THIS FILE ASSERTS IS THE EFFECT, NOT THE PROSE. A test that greps the SOP for
# the documented string proves nothing — that is precisely how this survived. So:
# feed the ledger two prior send-backs and it must say TWO, and feed it each known
# broken read and it must REFUSE rather than quietly answer zero.
#
#   ruby -Itest test/lib/bounce_ledger_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "net/http"
require_relative "../../bin/lib/bounce_ledger"

class BounceLedgerTest < Minitest::Test
  # A qa_feedback row as the activities API actually renders one.
  def row(kind: nil, summary: "Fixture drift in the board test", at: "2026-08-01T12:00:00Z")
    metadata = { "summary" => summary }
    metadata["kind"] = kind if kind
    { "created_at" => at, "activity_type" => "qa_feedback", "agent_slug" => "carl",
      "description" => summary, "metadata" => metadata }
  end

  def payload(*rows, total: nil)
    { "data" => rows,
      "meta" => { "page" => 1, "per_page" => 100, "total" => total || rows.size, "total_pages" => 1 } }
  end

  def response(code, body)
    res = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "")
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    res
  end

  # ---------------------------------------------------------------------------
  # THE EFFECT: two prior send-backs must count as TWO.
  # ---------------------------------------------------------------------------

  def test_two_prior_send_backs_report_two_and_trip_the_breaker
    verdict = BounceLedger.from_payload(payload(row(kind: "rework"), row(kind: "rework")))

    assert_equal 2, verdict.count, "two prior qa_feedback send-backs must count as two"
    assert verdict.tripped?, "two prior send-backs must TRIP the breaker"
  end

  def test_two_send_backs_survive_the_whole_http_path
    verdict = BounceLedger.from_response(
      response(200, JSON.generate(payload(row(kind: "rework"), row(kind: "rework"))))
    )

    assert_equal 2, verdict.count, "the count must survive status-check + parse, not just the parsed hash"
    assert verdict.tripped?
  end

  # ONE prior send-back is already enough: the SOP's rule is that the NEXT block
  # would be the second, and a repeat bounce is the operator's call.
  def test_one_prior_send_back_trips_the_breaker
    verdict = BounceLedger.from_payload(payload(row(kind: "rework")))

    assert_equal 1, verdict.count
    assert verdict.tripped?, "one prior send-back means the next block is the SECOND — escalate"
  end

  def test_a_task_with_no_history_is_clear
    verdict = BounceLedger.from_payload(payload)

    assert_equal 0, verdict.count
    refute verdict.tripped?, "a genuinely empty ledger is the ONE case that may answer zero"
  end

  # ---------------------------------------------------------------------------
  # MUTATION 1 — the unparsed response. THE original defect.
  # ---------------------------------------------------------------------------

  def test_handing_it_the_unparsed_response_object_raises_instead_of_answering_zero
    unparsed = response(200, JSON.generate(payload(row(kind: "rework"), row(kind: "rework"))))

    error = assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_payload(unparsed) }
    assert_match(/response object/i, error.message,
                 "the message must NAME the mistake — this is the error an agent will read at 2am")
  end

  # The mutation proof itself: the OLD recipe, run against the very payload that
  # has two bounces in it, produces 0 and raises NOTHING. If this ever stops being
  # true, the defect being pinned here has changed shape and the file needs a read.
  def test_the_old_hand_rolled_recipe_silently_answers_zero
    unparsed = response(200, JSON.generate(payload(row(kind: "rework"), row(kind: "rework"))))

    assert_nil unparsed["data"], "Net::HTTPResponse#[] is a HEADER read — there is no `data` header"
    assert_equal 0, Array(unparsed["data"]).size,
                 "this is the bug verbatim: two real bounces, counted as zero, with no exception raised"
  end

  # ---------------------------------------------------------------------------
  # MUTATION 2 — the 401. An auth failure must not DISARM the breaker.
  # ---------------------------------------------------------------------------

  def test_a_401_raises_instead_of_answering_zero
    unauthorized = response(401, JSON.generate("error" => "invalid token", "error_code" => "UNAUTHORIZED"))

    error = assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_response(unauthorized) }
    assert_match(/401/, error.message)
    assert_match(/not the same as no bounces/i, error.message,
                 "the message must say out loud that UNKNOWN is not CLEAR")
  end

  def test_a_401_body_reached_by_the_payload_path_also_raises
    parsed = JSON.parse(JSON.generate("error" => "invalid token", "error_code" => "UNAUTHORIZED"))

    assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_payload(parsed) }
  end

  def test_a_500_raises_instead_of_answering_zero
    assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_response(response(500, "<html>oops</html>")) }
  end

  # ---------------------------------------------------------------------------
  # MUTATION 3 — a body that is not JSON. The LENIENT parse every other board CLI
  # uses (TaskBoard.parse_body's `rescue {}`) would score this zero.
  # ---------------------------------------------------------------------------

  def test_a_non_json_body_raises_instead_of_answering_zero
    error = assert_raises(BounceLedger::UnreadableResponse) do
      BounceLedger.from_response(response(200, "<!DOCTYPE html><title>Application error</title>"))
    end
    assert_match(/not JSON/i, error.message)
  end

  def test_an_empty_body_raises_instead_of_answering_zero
    assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_response(response(200, "")) }
  end

  def test_a_payload_without_a_data_array_raises_instead_of_answering_zero
    assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_payload({ "meta" => { "total" => 0 } }) }
  end

  def test_a_json_array_at_the_top_level_raises_instead_of_answering_zero
    assert_raises(BounceLedger::UnreadableResponse) { BounceLedger.from_response(response(200, "[]")) }
  end

  # ---------------------------------------------------------------------------
  # THE THIRD WAY THE COUNT WAS WRONG — row-kind mismatch (over-count).
  # ---------------------------------------------------------------------------

  def test_an_escalation_row_is_not_itself_a_bounce
    verdict = BounceLedger.from_payload(payload(row(kind: "dependency", summary: "Escalated: base branch dispute")))

    assert_equal 0, verdict.count,
                 "a dependency block IS the escalation — counting it would let the breaker's own output re-trip it"
    refute verdict.tripped?
  end

  def test_an_environment_blocker_is_not_a_bounce
    verdict = BounceLedger.from_payload(payload(row(kind: "environment", summary: "Devnet RPC down")))

    assert_equal 0, verdict.count, "a blocked desk is not a review send-back"
  end

  def test_a_rework_row_still_counts_alongside_non_bounce_rows
    verdict = BounceLedger.from_payload(
      payload(row(kind: "environment"), row(kind: "rework"), row(kind: "dependency"))
    )

    assert_equal 1, verdict.count, "only the rework row is a send-back"
    assert verdict.tripped?
    assert_equal({ "environment" => 1, "rework" => 1, "dependency" => 1 }, verdict.by_kind)
  end

  # FAIL SAFE. A row written before kinds were stamped cannot be classified, and in a
  # SAFETY mechanism the safe reading of an unclassifiable row is "this might be a
  # bounce". Missing a real bounce is the failure this whole module is about; an
  # extra escalation is merely noise.
  def test_a_legacy_row_with_no_kind_counts
    verdict = BounceLedger.from_payload(payload(row(kind: nil)))

    assert_equal 1, verdict.count, "an unclassifiable row must count — fail safe, not fail quiet"
    assert_equal({ "unknown" => 1 }, verdict.by_kind)
  end

  def test_an_unrecognized_kind_is_treated_as_unknown_and_counts
    verdict = BounceLedger.from_payload(payload(row(kind: "gibberish")))

    assert_equal 1, verdict.count
    assert_equal({ "unknown" => 1 }, verdict.by_kind)
  end

  # ---------------------------------------------------------------------------
  # Truncation — a partial page must never masquerade as the whole ledger.
  # ---------------------------------------------------------------------------

  def test_truncation_is_detected_when_meta_total_exceeds_the_rows_returned
    assert BounceLedger.truncated?(payload(row(kind: "rework"), total: 140))
    refute BounceLedger.truncated?(payload(row(kind: "rework")))
  end

  # ---------------------------------------------------------------------------
  # Rendering detail the CLI leans on.
  # ---------------------------------------------------------------------------

  def test_a_row_without_a_summary_falls_back_to_the_first_line_of_the_description
    raw = { "created_at" => "2026-08-02T09:00:00Z", "metadata" => { "kind" => "rework" },
            "description" => "Missing regression test\nSecond line ignored" }
    verdict = BounceLedger.from_payload({ "data" => [raw] })

    assert_equal "Missing regression test", verdict.rows.first.summary
  end

  def test_a_malformed_row_does_not_crash_the_read
    verdict = BounceLedger.from_payload({ "data" => [nil, "nonsense", { "metadata" => "not-a-hash" }] })

    assert_equal 3, verdict.count, "unreadable ROWS still count — fail safe"
  end
end

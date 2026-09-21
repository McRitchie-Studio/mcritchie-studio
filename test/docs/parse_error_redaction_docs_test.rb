# frozen_string_literal: true

require "test_helper"

# Tripwire for the never-interpolate-a-quoting-exception rule
# (task document-parse-error-redaction-rule, 2026-09-21).
#
# The rule existed at three code sites and in no module doc, which is how it
# had to be rediscovered each time: `JSON::ParserError#message` echoes its input
# from the failure point to end of stream, so parsing a credential and
# interpolating the message writes the key into Postgres (ErrorLog stores
# `message` verbatim) and publishes it to Sentry and the admin UI.
#
# Documenting it creates a NEW failure mode — prose that outlives the code it
# describes. So this binds the two: the doc must state the rule, and each
# in-repo site it cites must still carry a rescue that reports position rather
# than the message.
#
# WHAT IT CANNOT SEE: the third site lives in `mcritchie-industries`, another
# repo. It is cited in the doc because the rule is cross-repo, and it is
# deliberately NOT asserted here — a test that reads another checkout passes or
# fails on whether that checkout happens to be on this disk.
class ParseErrorRedactionDocsTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/agents/modules/backend-discipline.md")

  # The sites this repo owns, as the doc's table names them.
  GUARDED_SERVICES = [
    "app/services/gmail/credentials.rb",
    "app/services/workspace/credentials.rb"
  ].freeze

  def doc_body = @doc_body ||= DOC.read.gsub(/[*`]/, "").gsub(/\s+/, " ")

  test "[static] backend discipline states the rule" do
    assert doc_body.match?(/never interpolate an exception message that quotes its input/i),
      "backend-discipline.md must carry the rule under Error Visibility — it lived at three code " \
      "sites and in no doc, which is why it kept being rediscovered"

    assert doc_body.match?(/position only/i),
      "the doc must say what to report INSTEAD of the message"
  end

  test "[static] the doc cites every in-repo site, and every cited site still guards" do
    GUARDED_SERVICES.each do |rel|
      assert doc_body.include?(rel),
        "backend-discipline.md must cite #{rel} — a rule with no examples is a rule nobody applies"

      source = Rails.root.join(rel).read

      assert source.match?(/rescue JSON::ParserError/),
        "#{rel} is cited by backend-discipline.md as carrying the guard, and no longer rescues " \
        "JSON::ParserError — either restore the rescue or stop citing it"

      # The defect itself: the bare message reaching a raise or a log. A guarded
      # site slices a position out of it first.
      refute source.match?(/(?:raise|warn|puts|logger\.\w+)[^\n]*#\{e\.message\}/),
        "#{rel} interpolates a bare e.message; JSON::ParserError echoes its input, so this writes " \
        "credential bytes into ErrorLog and Sentry. Report position only."

      # ANCHORED, not merely sliced. A bare `e.message[/\d+/]` takes the first
      # digit run, which on a key with a literal line break inside private_key
      # IS key material — measured. The pattern must require the literal words
      # `at line` and `column`, which key bytes do not contain.
      assert source.match?(%r{e\.message\[/at line .*column}),
        "#{rel} must slice the message with the ANCHORED pattern " \
        "(e.message[/at line \\d+ column \\d+/]) — a bare digit run returns key bytes"

      assert source.match?(/position unreported/),
        "#{rel} must fall back to a fixed string when the pattern misses, never to the raw message"
    end
  end

  test "[static] the doc names the near-miss, so the shape is not read as parser-only" do
    # The rule is about any value the caller did not choose, not about JSON. The
    # FRED client is the example that makes that concrete: safe only because the
    # endpoint it points at is keyless.
    assert doc_body.match?(/fred_client\.rb/i),
      "the doc must name the FRED URL interpolation near-miss — without it the rule reads as a " \
      "JSON::ParserError quirk rather than a shape"

    assert doc_body.match?(/keyless/i),
      "the near-miss is only a near-miss because the endpoint is keyless; say so, or it reads as safe"
  end

  test "[static] the doc teaches the anchored slice, not just \"report the position\"" do
    # "Report the position" was already the rule, and following it still leaked:
    # the bare digit run reads as a position and is not one. The doc has to say
    # which slice, or the next reader reinvents the same bug.
    assert doc_body.match?(/at line \\d\+ column \\d\+/),
      "the doc must name the ANCHORED pattern — 'report the position' alone is what leaked"

    assert doc_body.match?(/987654321/),
      "the doc must carry the MEASUREMENT that shows a bare digit run returning key bytes; " \
      "without it this reads as a style preference rather than a leak"

    assert doc_body.match?(/position unreported/i),
      "the doc must require a fixed-string fallback, never the raw message"
  end

  test "[static] the doc warns that a leak test must not print the leak" do
    # minitest's message() appends the default to a custom one, so assert_match
    # and friends dump their haystack either way. A leak test written with them
    # prints the secret it is asserting the absence of.
    assert doc_body.match?(/leak test must not print the leak/i),
      "the doc must carry the test-writing trap — otherwise the first test written against this " \
      "rule prints the very bytes it is guarding"
  end
end

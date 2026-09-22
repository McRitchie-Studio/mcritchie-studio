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

  # THE FABRICATION LANDED IN A FILE THIS GUARD DID NOT READ. `workspace-provision`
  # is an SOP: it hands an operator a `heroku run bin/rails runner` one-liner that
  # parses a credential, which inherits no service's rescue, so it teaches the rule
  # in its own words — and it published the invented figure for a day after this
  # file's own retraction landed. A guard scoped to the doc that happens to own the
  # rule cannot see the doc that APPLIES it.
  APPLYING_DOCS = [
    Rails.root.join("docs/agents/agents/steffon/sops/workspace-provision.md")
  ].freeze

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

    # NO PIN ON A SPECIFIC MEASURED VALUE, and that is a deliberate correction.
    # This assertion used to require the literal string "987654321" — a figure
    # taken from a hand-built fixture, not from a real key. So an agent who
    # re-measured, found the true value and corrected the doc REDDENED this
    # suite, and the failure message told them to restore the false number. A
    # guard that punishes re-measurement is this rule running backwards.
    #
    # What is pinned instead is the SHAPE the rule needs: the anchored pattern
    # above, the fixed-string fallback below, and — since the argument is that
    # the bare form is not a position at all — that the doc still shows the bare
    # form being contrasted with it. The numbers are free to move when someone
    # measures again, which is what we want them to do.
    assert doc_body.match?(%r{e\.message\[/\\d\+/\]}),
      "the doc must still SHOW the bare form it is arguing against — the rule is a contrast, " \
      "and without the losing side it reads as an arbitrary preference"

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

  # PLAIN WAS ONLY HALF THE RULE, and the missing half is the one that leaked.
  # minitest stops a test at its FIRST failed assertion and appends its default
  # message, so an `assert_equal` on the guarded value placed BEFORE the refute
  # fails there, prints the bytes the refute existed to catch, and the refute
  # never runs. Measured on test/services/workspace/error_slug_test.rb under a
  # broken-guard mutant: most of its failures printed guarded content before the
  # reorder, none after.
  #
  # Until this landed, the ordering half lived ONLY in a comment atop that test
  # file and in its own self-parsing guard. A leak test written in any OTHER
  # file therefore got the plain half and none of this — the same "the rule lived
  # at code sites and in no doc" failure the assertions above exist to end, one
  # level up.
  #
  # PINNED AS SHAPE, NOT AS A MEASURED VALUE — the same correction already
  # recorded above, where a pinned figure reddened this suite for the agent who
  # re-measured it and told them to restore a false one. The failure counts
  # belong in the doc's prose, where re-measuring them is welcome.
  test "[static] the doc states the ORDERING half, not just the plain half" do
    assert doc_body.match?(/the refute must also run FIRST/i),
      "backend-discipline.md carries the PLAIN half only. A leak test written to it can still " \
      "print the leak, by reaching a shape check before the refute"

    assert doc_body.match?(/stops a test at its first failed assertion/i),
      "the doc must say WHY the order decides it — without minitest's first-failure semantics the " \
      "rule reads as a style preference, and the next writer reorders it back"

    assert doc_body.match?(/haystack is an integer/i),
      "the doc must grant the exemption on the property that EARNS it — an integer haystack. " \
      "Scoping it to one assertion method instead condemns an assert_equal on a length, which is " \
      "exempt for exactly the same reason"
  end

  # Every doc that hands an operator a credential-parsing one-liner has to teach
  # the anchored form, and none may re-publish the retracted figure. This is the
  # assertion that would have caught the sibling copy on the day it was written.
  test "[static] a doc that teaches the rule uses the anchored slice and no retracted figure" do
    APPLYING_DOCS.each do |path|
      body = path.read
      rel = path.relative_path_from(Rails.root).to_s

      assert body.match?(/at line .d\+ column .d\+/),
        "#{rel} hands the operator a rescue on a credential and must show the ANCHORED slice"

      assert body.match?(/position unreported/),
        "#{rel} must fall back to a fixed string, never to the raw message"

      # THE FIGURE MAY NOT APPEAR INSIDE A FENCED BLOCK. A proximity window was
      # the first shape of this assertion and it did not bite: the 600 characters
      # before a fresh copy still reached back into the retraction's own prose, so
      # the control passed. The failure mode is not "the digits appear" — they have
      # to, in the retraction that names them — it is the digits appearing as
      # OUTPUT. A fence is what makes a number read as something a command printed.
      fenced = body.scan(/```.*?```/m).join("\n")

      refute fenced.match?(/987654/),
        "#{rel} prints the retracted figure inside a fenced block, where it reads as measured " \
        "output. It was TYPED onto a real PKCS#8 prefix and labelled Measured; the real answer " \
        "is \"9\". Name it in prose if you are retracting it, never in a fence."

      assert body.match?(/retract|fabricat/i),
        "#{rel} must keep the retraction that explains why the figure it once published was false"
    end
  end
end

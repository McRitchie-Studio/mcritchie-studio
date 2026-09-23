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

  # THE SENTENCES THAT GRANT THE EXEMPTION, ASKED ONE AT A TIME. `doc_body`
  # collapses the file onto one line, so a question about what the exemption SAYS
  # cannot be asked of it — a phrase anywhere in the file answers. The first
  # attempt at this narrowed to a PASSAGE and then asked its questions of the
  # UNION of every granting sentence in the file, which review measured as a leak
  # of its own: a narrow grant in one paragraph and an unrelated exemption in
  # another answered green together. So each granting sentence is held to the
  # property by itself, and a doc that grants twice has to get it right twice.
  # `exemption` is not a grant — only a sentence that says something IS exempt.
  GRANT = /\bexempts?(?:ed)?\b/i

  # A grant states a PROPERTY: it quantifies over the assertions it covers — "any
  # assertion whose haystack is an INTEGER", "…whatever the assertion" — instead
  # of naming the one method the writer happened to be holding.
  UNIVERSAL_GRANT = Regexp.union(
    /\b(?:any|every|each|all)\b[^.;:]{0,40}\b(?:assertions?|haystacks?)\b/i,
    /\b(?:whatever|regardless of)\b[^.;:]{0,40}\b(?:assertions?|methods?)\b/i
  )

  # …and it must not close again in the same breath. That is the ordinary way an
  # exemption gets narrowed, and review reproduced it here: "Only an
  # `assert_operator` on a length is exempt; an `assert_equal` on one is not,
  # whatever the haystack — even an integer." It reads as a grant until the
  # closer, and every structural test of the grant alone passes it.
  CLOSING_QUANTIFIER = /\b(?:only|no other|none other|nothing else|never|except|excluding)\b/i

  # THE CLOSER IS READ FROM THE CLAUSE THAT GRANTS, NOT FROM THE WHOLE SENTENCE.
  #
  # Asked of the whole sentence, this reds correct prose. Measured at the review of
  # PR 1518: "…any assertion whose haystack is an INTEGER is exempt by construction,
  # since only the payload can hold the secret" is a CORRECT universal grant whose
  # `only` lives in the JUSTIFICATION, not in the scope — and `except` does the same
  # to a legitimate refinement. The guard failed CLOSED (it quotes the sentence, so a
  # writer rewords), which is why it was filed as friction rather than a leak.
  #
  # So a REASON clause — one opening with `because`/`since`, leading or trailing — is
  # dropped before the question is asked. What is left is the clause that actually
  # grants, and that is where a self-closing grant does its closing.
  REASON_LEAD = /\A\s*(?:because|since|given that|on the grounds that)\b[^,;]*[,;]\s*/i
  REASON_TAIL = /[,;]\s*(?:because|since|given that|on the grounds that)\b.*\z/i

  # …BUT A REASON THAT NAMES AN ASSERTION IS NOT MERELY EXPLAINING. "…is exempt,
  # since only an `assert_operator` is safe" closes the grant exactly as surely as
  # "Only an `assert_operator` … is exempt" does; the conjunction is grammar, not
  # meaning. So the carve-out is withheld from any reason clause carrying this
  # vocabulary, which is the only vocabulary this doc's narrowings have ever used.
  # Without it the narrowing releases the LAST case in SELF_CLOSING_GRANTS below
  # (measured), and dropping coverage silently is the failure recorded further down
  # this file. It does NOT make the narrowing a superset — see that table's header.
  SCOPING_TERM = /\bassert[a-z_]*\b|\bmethods?\b|\bassertions?\b/i

  # THE RULE, extracted so the controls below drive the REAL one rather than a copy.
  def granting_clause(sentence)
    [REASON_LEAD, REASON_TAIL].reduce(sentence.to_s) do |text, pattern|
      clause = text[pattern]
      clause && !clause.match?(SCOPING_TERM) ? text.sub(pattern, " ") : text
    end
  end

  def self_closing_grant?(sentence) = granting_clause(sentence).match?(CLOSING_QUANTIFIER)

  def doc_sentences
    @doc_sentences ||= DOC.read.split(/\n{2,}/)
                          .map { |para| para.gsub(/[*`]/, "").gsub(/\s+/, " ") }
                          .flat_map { |para| para.split(/(?<=[.!?])\s+/) }
  end

  def granting_sentences
    @granting_sentences ||= doc_sentences.select { |sentence| sentence.match?(GRANT) }
  end

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

    # KEPT, NOT REPLACED — and that is the rule this task learned the hard way.
    # The first version of this fix DELETED the assertion below and put the
    # structural ones underneath in its place. Review measured what that cost:
    # narrow the doc to "Only an `assert_operator` on a length is exempt; an
    # `assert_equal` on one is not, whatever the haystack — even an integer" —
    # the ordinary way an exemption gets weakened, and precisely the defect this
    # message names — and the deleted assertion REDS while the replacement passed
    # GREEN at 7 runs, 26 assertions. A better assertion is not a superset until
    # it has been shown to red every case the old one did. Add first; delete only
    # once the measurement says you may.
    assert doc_body.match?(/haystack is an integer/i),
      "the doc must grant the exemption on the property that EARNS it — an integer haystack. " \
      "Scoping it to one assertion method instead condemns an assert_equal on a length, which is " \
      "exempt for exactly the same reason"

    # WHAT THE PHRASE ABOVE CANNOT SEE. It matches anywhere in the file, so the
    # round-1 wording review bounced — "an `assert_operator` on a LENGTH is
    # exempt by construction — its haystack is an integer" — satisfies it while
    # scoping the exemption to one method. The structural question is therefore
    # asked of THE SENTENCE THAT GRANTS, one grant at a time: does it quantify
    # over the assertions it covers, and does it close itself again in the same
    # breath? Both are properties of that sentence, so no trailing sentence
    # elsewhere in the paragraph can rescue a grant that fails them — the first
    # shape of this assertion could be rescued exactly that way.
    #
    # NO METHOD COUNT SURVIVES HERE, and that is a measured retreat rather than a
    # simplification. Requiring the grant to name two methods was this
    # assertion's first shape and review ruled it out in both directions: prose
    # naming two while granting to one passes, and the purest property-only grant
    # — "any assertion whose haystack is an INTEGER is exempt" — names none and
    # reds. Review left the door open to keeping a count as a SECONDARY check, so
    # the one structural form was tried and measured too: refusing a grant that
    # names EXACTLY ONE method. It reds "any assertion whose haystack is an
    # integer is exempt — an `assert_operator` on a length, say", a universal
    # grant carrying one illustrative example, which is correct prose. A guard
    # that punishes correct prose is the failure already recorded at the top of
    # this file, so the count is gone. STILL NO MEASURED VALUE PINNED — which
    # methods the doc names, and every failure count in that paragraph, stay free
    # to move when someone measures again.
    assert granting_sentences.any?,
      "no sentence in backend-discipline.md grants the exemption any more, so the rule now " \
      "condemns a length assertion — which cannot hold the secret and never could"

    granting_sentences.each do |grant|
      refute self_closing_grant?(grant),
        "this sentence grants the exemption and then closes it again in the same breath, which " \
        "narrows it to whatever it happened to name: #{granting_clause(grant).strip}\n" \
        "(asked of the granting clause; the full sentence was: #{grant})"

      assert grant.match?(UNIVERSAL_GRANT),
        "the exemption must be granted over the ASSERTIONS it covers — any assertion whose " \
        "haystack is an integer — not handed to one method that happens to have that " \
        "haystack: #{grant}"

      assert grant.match?(/haystack/i) && grant.match?(/integer/i),
        "the grant must name the property that earns the exemption — an integer haystack — in " \
        "the sentence that grants it: #{grant}"
    end
  end

  # SENTENCES THAT GENUINELY CLOSE THEIR OWN GRANT — every one must still red.
  #
  # THIS TABLE IS THE COVERAGE THE NARROWING KEEPS — NOT a proof that it is a
  # superset; this comment claimed that until review measured otherwise (below).
  # The rule it replaces asked the
  # closer question of the WHOLE sentence, and the honest objection to narrowing any
  # assertion is that a narrower one silently drops coverage. The old rule cannot be
  # kept alongside, because the old rule IS the false positive — so its coverage is
  # kept HERE instead, as cases, driven through the shipping predicate. Each one is
  # asserted to have been caught by the old rule too, so the table cannot drift into
  # testing something the old rule never reached.
  #
  # THE RESIDUAL HOLE, MEASURED at the G2 review 2026-09-22 and reproduced twice: a
  # closer sitting in a comma-led reason clause that NAMES NO ASSERTION is released.
  # Planted in the live doc, "…is exempt by construction, because only a length CHECK
  # is" leaves this whole file GREEN, while the rule this one replaces reds on it.
  # Swap "check" for "assertion" and SCOPING_TERM catches it again — so what stays
  # covered turns on which synonym the writer reached for. Five cases cannot
  # establish a property over prose. Closing it is its own card with its own
  # false-positive budget, not a widened SCOPING_TERM here.
  #
  # Spelled as `doc_sentences` would hand them over: backticks stripped, whitespace
  # collapsed. The first is the round-1 wording review measured and bounced.
  SELF_CLOSING_GRANTS = [
    "Only an assert_operator on a length is exempt; an assert_equal on one is not, " \
      "whatever the haystack — even an integer.",
    "Any assertion whose haystack is an integer is exempt, except an assert_equal.",
    "Every assertion whose haystack is an integer is exempt and no other assertion is.",
    "An assertion whose haystack is an integer is exempt; nothing else is.",
    # THE CASE THE CARVE-OUT HAD TO BE WITHHELD FROM. The closer sits inside a `since`
    # clause, which is exactly the shape dropped above — but it NAMES AN ASSERTION, so
    # it is narrowing the scope rather than explaining it. Without SCOPING_TERM this
    # one goes green and the narrowing stops being a superset.
    "Any assertion whose haystack is an integer is exempt, since only an assert_operator is safe."
  ].freeze

  # CORRECT PROSE THE OLD RULE CONDEMNED — every one must now pass. The first is the
  # example review measured on the day it filed this defect.
  INNOCUOUS_GRANTS = [
    "Any assertion whose haystack is an INTEGER is exempt by construction, since only " \
      "the payload can hold the secret.",
    "Any assertion whose haystack is an integer is exempt, because only the message can " \
      "carry the key.",
    "Because only the message can carry the key, any assertion whose haystack is an " \
      "integer is exempt.",
    "Any assertion whose haystack is an integer is exempt, since nothing else in the " \
      "rescue is interpolated."
  ].freeze

  # COLLECTED, NOT ASSERTED IN THE LOOP. Minitest stops a test at its first failed
  # assertion, so an in-loop `assert` proves the rule against member 1 and says nothing
  # about the rest — and a mutation that releases only the LAST case would be invisible
  # behind an earlier one. Collecting makes each member separately visible in one run.
  test "[control] a genuine self-closing grant still reds after the narrowing" do
    unreached = SELF_CLOSING_GRANTS.reject { |g| g.match?(GRANT) && g.match?(CLOSING_QUANTIFIER) }
    assert_empty unreached,
      "premise: every case here must be one GRANT selects AND the OLD whole-sentence rule " \
      "caught. A case failing either is not preserved coverage, it is a new invention, and " \
      "the real path would never reach it."

    released = SELF_CLOSING_GRANTS.reject { |g| self_closing_grant?(g) }

    assert_empty released.map { |g| "#{g}\n  → granting clause read as: #{granting_clause(g).strip}" },
      "the narrowing RELEASED #{released.size} grant(s) that close themselves. The closer is " \
      "read from the granting clause, and each of these closes IN that clause — a narrowing " \
      "that drops one of them is not a superset of the rule it replaced."
  end

  test "[control] an innocuous only or except in the reason now stays green" do
    unreached = INNOCUOUS_GRANTS.reject { |g| g.match?(GRANT) && g.match?(CLOSING_QUANTIFIER) }
    assert_empty unreached,
      "premise: every case here must be one GRANT selects AND the OLD whole-sentence rule " \
      "RED. A case the old rule never flagged cannot show the fix fixed anything — this " \
      "control would then pass in both states and separate nothing."

    condemned = INNOCUOUS_GRANTS.select { |g| self_closing_grant?(g) }

    assert_empty condemned.map { |g| "#{g}\n  → granting clause read as: #{granting_clause(g).strip}" },
      "#{condemned.size} piece(s) of correct prose still red. The closer in each is in the " \
      "REASON, not in the scope, and a guard that punishes correct prose is the failure " \
      "recorded at the top of this file."
  end

  # [control] THE LIVE DOC, ASKED THE SAME WAY. The two tables above are fixtures; this
  # pins that the sentence actually in backend-discipline.md today is one the narrowed
  # rule clears, and that the carve-out ate a REASON rather than part of the grant.
  #
  # MEASURED WHILE WRITING THIS, because the first cut of it asserted the opposite: the
  # live grant DOES carry a trailing reason clause ("…is exempt by construction, because
  # an integer cannot hold the secret"), so the carve-out fires on the real doc rather
  # than only on fixtures. That is the point worth pinning — a rule whose new branch
  # never runs against the live corpus is a rule nobody has tested.
  test "[control] the doc's own granting sentence survives the narrowed reading" do
    assert_equal 1, granting_sentences.size,
      "this control is written against ONE granting sentence; the doc now has " \
      "#{granting_sentences.size}, so re-derive it rather than letting it pass on a " \
      "sentence nobody looked at: #{granting_sentences.inspect}"

    grant = granting_sentences.first
    clause = granting_clause(grant)

    refute self_closing_grant?(grant), "the live grant reads as self-closing: #{grant}"

    refute_equal grant, clause,
      "the carve-out no longer fires on the live doc, so its branch is exercised by " \
      "fixtures alone. Either the doc's reason clause was reworded — re-derive this " \
      "control against the new sentence — or the carve-out stopped matching: #{grant}"

    removed = grant.delete_prefix(clause.rstrip)
    assert removed.match?(/\A[,;]\s*(?:because|since|given that|on the grounds that)\b/i),
      "the carve-out removed something that is not a reason clause, which means it is " \
      "eating text the closer question needed: #{removed.inspect}"

    assert clause.match?(GRANT),
      "the carve-out ate the grant itself — what is left grants nothing: #{clause}"
    assert clause.match?(/haystack/i) && clause.match?(/integer/i),
      "the carve-out ate the property that earns the exemption: #{clause}"
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

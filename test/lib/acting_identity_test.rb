# frozen_string_literal: true

# Unit tests for ActingIdentity — "who is `gh` about to act as?", asked before a merge.
#
# NO gh, NO network, NO credential of any kind: the classifier is pure, so every branch
# is reachable from synthetic inputs. That matters more than usual here, because the
# branch this guard exists for (a PERSON about to merge) cannot be produced on demand
# without signing a human in, and the branch that admits a merge (an App installation's
# 403) cannot be produced without a live App token. Both are strings here.
#
# THE FIXTURES ARE VERBATIM gh OUTPUT, captured 2026-08-30 from the real CLI against the
# real API — the same discipline GhAuthRetry's regex test uses, and for the same reason:
# a guard tuned to output someone REMEMBERED matches nothing when it meets the real
# thing, and "no match" here means a silent fallback to UNKNOWN.
#
# Run directly:  ruby -Itest test/lib/acting_identity_test.rb

require "minitest/autorun"
require "json"
require_relative "../../bin/lib/acting_identity"

class ActingIdentityTest < Minitest::Test
  # Verbatim: an App INSTALLATION token calling `gh api user`. An installation is not a
  # user, so /user has no answer for it — and that refusal IS the proof it is a bot.
  APP_403_BODY = <<~TXT
    {
      "message": "Resource not accessible by integration",
      "documentation_url": "https://docs.github.com/rest/users/users#get-the-authenticated-user",
      "status": "403"
    }
  TXT
  APP_403_GH_LINE = "gh: Resource not accessible by integration (HTTP 403)\n"

  # Verbatim shape: a signed-in PERSON. This is what the keyring answered on 2026-08-29.
  HUMAN_200 = JSON.generate("login" => "alexmcritchie", "id" => 12_345, "type" => "User")

  # Verbatim: an EXPIRED credential, captured live during the 2026-08-30 outage.
  EXPIRED_401_BODY = <<~TXT
    {
      "message": "Bad credentials",
      "documentation_url": "https://docs.github.com/rest",
      "status": "401"
    }
  TXT
  EXPIRED_401_GH_LINE = "gh: Bad credentials (HTTP 401)\n"

  # A probe result, in the [stdout, stderr, success] shape `check` consumes.
  APP_PROBE = [APP_403_BODY, APP_403_GH_LINE, false].freeze
  HUMAN_PROBE = [HUMAN_200, "", true].freeze
  EXPIRED_PROBE = [EXPIRED_401_BODY, EXPIRED_401_GH_LINE, false].freeze

  # --- the discriminator -------------------------------------------------------

  # The one identity permitted to merge, recognised by its REFUSAL. Order is
  # load-bearing in the classifier: this arrives on a FAILED call, so a `success` test
  # placed first would discard the evidence and answer UNKNOWN for a good App token.
  def test_an_app_installation_refusal_classifies_as_app
    assert_equal ActingIdentity::APP, ActingIdentity.classify(*APP_PROBE)
  end

  # gh phrases this differently per verb and wraps it either as the API body or its own
  # "gh: … (HTTP 403)" line. Either alone must still classify — a caller that captured
  # only one stream must not be told its bot is an unknown.
  def test_either_stream_alone_still_identifies_the_app
    assert_equal ActingIdentity::APP, ActingIdentity.classify(APP_403_BODY, "", false),
                 "the refusal on stdout alone must still identify the App"
    assert_equal ActingIdentity::APP, ActingIdentity.classify("", APP_403_GH_LINE, false),
                 "and on stderr alone — which stream carries it varies by gh version"
  end

  # A 200 with a login is a PERSON, and a person may never merge: the whole two-identity
  # audit model is that `agent` merges and a human does not.
  def test_a_successful_user_body_classifies_as_human
    assert_equal ActingIdentity::HUMAN, ActingIdentity.classify(*HUMAN_PROBE)
    assert_equal "alexmcritchie", ActingIdentity.login_from(HUMAN_200)
  end

  # REGRESSION, found by the integration tier on this very change. An earlier draft
  # JOINED stdout and stderr and parsed the join as JSON; Ruby's "already initialized
  # constant" warnings landed on stderr, the join stopped being valid JSON, and a
  # PERSON was classified UNKNOWN. It failed closed, so nothing merged — but the
  # operator would have been told the identity was undeterminable about a credential
  # we could name, and sent to mint a token that was never the problem. gh may print
  # anything on stderr: a deprecation notice, an upgrade nag, a proxy's chatter.
  def test_noise_on_stderr_does_not_hide_a_human
    noise = "ruby: warning: already initialized constant Gem::Platform::JAVA\nA new release of gh is available\n"

    assert_equal ActingIdentity::HUMAN, ActingIdentity.classify(HUMAN_200, noise, true),
                 "stderr noise must not turn a nameable person into an unknown"
  end

  # The same tolerance one layer down: a body with a stray line around it still yields
  # the login. Being generous here can only ever add a REFUSAL (recognising a human is
  # what refuses), never a merge — so it is the safe direction to be lenient in.
  def test_a_login_is_read_through_a_stray_line_around_the_body
    assert_equal "alexmcritchie", ActingIdentity.login_from("Warning: something\n#{HUMAN_200}\n")
  end

  # FAIL CLOSED, the property this guard lives or dies on. Everything that is not
  # positive proof of one identity or the other is UNKNOWN — never "probably fine".
  def test_everything_unrecognised_fails_closed_as_unknown
    {
      "an expired credential" => [EXPIRED_401_BODY, EXPIRED_401_GH_LINE, false],
      "a bare network error" => ["", "Errno::ECONNREFUSED: Connection refused", false],
      "gh not installed" => ["", "Errno::ENOENT: No such file or directory - gh", false],
      "an empty failure" => ["", "", false],
      # THE DANGEROUS ONES: a SUCCESSFUL call whose body proves nothing. A stub, a proxy,
      # or a gh version change can answer 200 with content we cannot read, and reading
      # "it did not fail" as "it is a bot" is precisely the reasoning that lost the audit
      # trail in the first place.
      "success with an unparseable body" => ["not json at all", "", true],
      "success with an empty body" => ["", "", true],
      "success with a JSON array" => ["[]", "", true],
      "success with no login key" => [JSON.generate("id" => 1), "", true],
      "success with a blank login" => [JSON.generate("login" => "   "), "", true],
      # A login on STDERR is not a login: only the API body speaks for the account,
      # and anything may write to stderr.
      "a login that appears only on stderr" => ["", HUMAN_200, true]
    }.each do |label, (stdout, stderr, success)|
      assert_equal ActingIdentity::UNKNOWN, ActingIdentity.classify(stdout, stderr, success),
                   "#{label} must fail closed as UNKNOWN, never admit a merge"
    end
  end

  # The discriminator must not be confusable with a PERMISSIONS probe. A personal account
  # with `repo` scope can read pull requests, so "can it read PRs?" would wave through the
  # exact credential this guard exists to stop. /user separates BOT from HUMAN instead.
  def test_a_person_with_broad_scopes_is_still_refused
    powerful_person = JSON.generate("login" => "amcritchie", "type" => "User", "site_admin" => true)

    assert_equal ActingIdentity::HUMAN, ActingIdentity.classify(powerful_person, "", true)
  end

  # --- present-but-blank vs absent ---------------------------------------------

  # THE ROOT DEFECT. `gh` treats an empty GH_TOKEN as NOT SET and silently falls back to
  # its keyring; `GH_TOKEN="$(bin/gh-token)"` produces exactly that on a failed mint.
  def test_a_present_but_blank_gh_token_is_the_defect_shape
    ["", "   ", "\n"].each do |blank|
      assert ActingIdentity.blank_token?(env: { "GH_TOKEN" => blank }),
             "GH_TOKEN=#{blank.inspect} is present-but-blank — the 2026-08-29 shape"
    end
  end

  # ABSENT IS NOT A DEFECT, and conflating the two would make this guard cry wolf on
  # every ordinary session. A session that never exported a token may still have a
  # perfectly good bot credential in its keyring; only the PROBE can settle that.
  def test_an_absent_gh_token_is_not_the_defect_shape
    refute ActingIdentity.blank_token?(env: {}), "an absent GH_TOKEN is an ordinary state, not a defect"
    refute ActingIdentity.blank_token?(env: { "GH_TOKEN" => "ghs_realtoken" })
  end

  # --- the decision a merge actually reads --------------------------------------

  # A blank token is answered from the ENVIRONMENT, with no probe at all. Probing would
  # only report which innocent account gh borrowed; the defect is the call site that
  # exported a failed mint, so that is what the refusal names.
  def test_check_refuses_a_blank_token_without_probing
    probed = false
    prober = ->(**) { probed = true; HUMAN_PROBE }
    identity, message = ActingIdentity.check(env: { "GH_TOKEN" => "" }, prober: prober)

    assert_equal ActingIdentity::UNKNOWN, identity, "recoverable: a mint is exactly what it lacks"
    assert_match(/GH_TOKEN is set but EMPTY/, message)
    refute_match(/alexmcritchie/, message, "it must not blame the account gh would have borrowed")
    refute probed, "a blank GH_TOKEN needs no API call — gh has already decided to ignore it"
  end

  # The three verdicts a merge branches on, end to end through `check`.
  def test_check_maps_each_probe_result_to_a_merge_verdict
    {
      APP_PROBE => ActingIdentity::APP,
      HUMAN_PROBE => ActingIdentity::HUMAN,
      EXPIRED_PROBE => ActingIdentity::UNKNOWN
    }.each do |probe_result, expected|
      identity, message = ActingIdentity.check(env: {}, prober: ->(**) { probe_result })

      assert_equal expected, identity
      if expected == ActingIdentity::APP
        assert_nil message, "an App identity is the ONLY one that merges, and it needs no explanation"
      else
        refute_nil message, "every refusal must say why, at the knob that fixes it"
      end
    end
  end

  # A refusal is read in a terminal beside other output, and it has to be actionable.
  # These assert the CONTENT a blocked operator needs, not merely that a string exists.
  def test_a_human_refusal_names_the_account_and_the_remedy
    _identity, message = ActingIdentity.check(env: {}, prober: ->(**) { HUMAN_PROBE })

    assert_match(/alexmcritchie/, message, "name WHO gh would have acted as")
    assert_match(/gh-auth-refresh/, message, "and the command that fixes it")
  end

  # No refusal may ever carry the credential itself into a log or a terminal.
  def test_no_refusal_leaks_a_token
    secret = "ghs_supersecrettokenvalue"
    _identity, message = ActingIdentity.check(env: { "GH_TOKEN" => secret },
                                              prober: ->(**) { EXPIRED_PROBE })

    refute_includes message.to_s, secret
    refute_includes ActingIdentity.blank_token_message, "GH_TOKEN=", "the message names the var, never a value"
  end

  # A whole 403 body pasted into a refusal buries the sentence that matters.
  def test_an_unknown_refusal_quotes_one_trimmed_line
    message = ActingIdentity.unknown_message("#{'x' * 500}\nsecond line")

    refute_includes message, "second line", "only the first meaningful line is quoted"
    refute_includes message, "x" * 250, "a long line is trimmed, not pasted whole"
    assert_includes message, "...", "and the trim is visible as an ellipsis"
  end
end

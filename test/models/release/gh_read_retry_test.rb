require "open3"

require "test_helper"

# The retry POLICY for a cheap, idempotent `gh` read. Pure — reading, sleeping and
# minting are all injected — so every branch is exercised with no network, no clock
# and no real token.
#
# THE FAILURE TEXTS BELOW ARE VERBATIM. Both were captured from the real `gh` this
# lane runs, against the exact failing command
# (`gh run list --workflow qa-deploy.yml --limit 1 --json databaseId`), because the
# whole policy turns on classifying gh's words and a paraphrase would test a string
# nobody's gh ever prints. Measured 2026-09-22.
class Release::GhReadRetryTest < ActiveSupport::TestCase
  R = Release::GhReadRetry

  # A dead GH_TOKEN, measured: `GH_TOKEN=<dead> gh run list …` → exit 1, 0.24s.
  CREDENTIAL_REFUSAL = <<~TXT.freeze
    HTTP 401: Bad credentials (https://api.github.com/repos/McRitchie-Studio/mcritchie-studio/actions/workflows/qa-deploy.yml)
    Try authenticating with:  gh auth login
  TXT

  # The OTHER suspect class for the same symptom — a name that would not resolve
  # (the macOS negative-cache poisoning seen on this machine the same session).
  # Not credential-shaped, so it must keep the sleep-retry.
  RESOLUTION_FAILURE =
    "error connecting to api.github.com: dial tcp: lookup api.github.com: no such host".freeze

  # A scripted reader: returns the next [out, ok] pair per call and records the
  # credential it was handed each time.
  def scripted(*results)
    tokens = []
    reader = lambda do |token|
      tokens << token
      results[tokens.size - 1] || raise("read ##{tokens.size} was not scripted")
    end
    [reader, tokens]
  end

  def run_policy(results, minter: -> { "ghs_fresh" }, attempts: R::ATTEMPTS)
    reader, tokens = scripted(*results)
    sleeps = []
    mints  = 0
    counting_minter = minter && lambda {
      mints += 1
      minter.call
    }
    result = R.call(attempts: attempts, sleeper: ->(s) { sleeps << s }, minter: counting_minter, &reader)
    [result, tokens, sleeps, mints]
  end

  # --- the credential arm: re-mint, and do NOT sleep -----------------------

  test "[unit] REGRESSION: a credential refusal re-mints and retries AT ONCE — the measured failure clears" do
    result, tokens, sleeps, mints = run_policy([[CREDENTIAL_REFUSAL, false], ["35800673643", true]])

    assert result.ok?, "the read after the re-mint succeeded, so the policy must report success"
    assert_equal "35800673643", result.out
    assert_equal 1, mints, "exactly one mint — a second mint of the same identity fails identically"
    assert_equal [nil, "ghs_fresh"], tokens,
      "the ambient credential is tried first; the RETRY carries the freshly minted one"
    assert_empty sleeps,
      "a dead token does not become live by waiting — the recovery read must not be delayed"
    assert result.reminted?
    assert_equal "ghs_fresh", result.token, "the caller needs the token for the REST of the lane"
  end

  test "[unit] the recovered token is carried, so the dispatch after the read does not ride the dead one" do
    result, = run_policy([[CREDENTIAL_REFUSAL, false], ["7", true]])

    assert_equal "ghs_fresh", result.token
  end

  # --- the transient arm: sleep, and do NOT mint ---------------------------

  test "[unit] a NON-credential failure keeps the bounded sleep-retry and never mints" do
    result, tokens, sleeps, mints = run_policy(
      [[RESOLUTION_FAILURE, false], [RESOLUTION_FAILURE, false], ["35800673643", true]]
    )

    assert result.ok?
    assert_equal 0, mints, "a resolution failure is not a credential fault — minting would be the wrong remedy"
    assert_equal [R::DELAY_SECONDS, R::DELAY_SECONDS], sleeps, "it waits between reads, as it always did"
    assert_equal [nil, nil, nil], tokens, "no token was minted, so every read uses the ambient credential"
    assert_not result.reminted?
  end

  test "[unit] a first-attempt pass reads once, never sleeps, never mints" do
    result, tokens, sleeps, mints = run_policy([["35800673643", true]])

    assert result.ok?
    assert_equal 1, result.reads
    assert_equal [nil], tokens
    assert_empty sleeps, "the happy path never delays the sweep"
    assert_equal 0, mints, "the happy path never spends a mint"
    assert_equal :ok, result.cause
  end

  # --- giving up, and giving up EARLY where waiting is pointless -----------

  test "[unit] a credential refusal that persists AFTER the re-mint stops — it does not burn the budget" do
    result, tokens, sleeps, mints = run_policy(
      [[CREDENTIAL_REFUSAL, false], [CREDENTIAL_REFUSAL, false]]
    )

    assert_not result.ok?
    assert_equal :credential, result.cause
    assert_equal 2, result.reads, "two reads, then the verdict — a second mint fails identically"
    assert_equal 1, mints
    assert_empty sleeps
    assert_equal [nil, "ghs_fresh"], tokens
    assert_includes result.out, "Bad credentials", "the operator is shown gh's own words"
  end

  test "[unit] a credential refusal with NO mint available stops immediately, and says so" do
    result, tokens, sleeps, mints = run_policy([[CREDENTIAL_REFUSAL, false]], minter: -> { "" })

    assert_not result.ok?
    assert_equal :unmintable, result.cause
    assert_equal 1, result.reads, "further reads of a credential nobody can refresh are pure delay"
    assert_equal 1, mints
    assert_empty sleeps
    assert_equal [nil], tokens
    assert_nil result.token
    assert_not result.reminted?, "a mint that produced nothing is not a re-mint"
  end

  test "[unit] a nil minter is a normal configuration — it stops rather than raising" do
    result, = run_policy([[CREDENTIAL_REFUSAL, false]], minter: nil)

    assert_not result.ok?
    assert_equal :unmintable, result.cause
  end

  test "[unit] a persisting transient exhausts the budget and reports the LAST failure" do
    results = Array.new(R::ATTEMPTS) { [RESOLUTION_FAILURE, false] }
    results[-1] = ["error connecting to api.github.com: the last word", false]
    result, _tokens, sleeps, mints = run_policy(results)

    assert_not result.ok?
    assert_equal :exhausted, result.cause
    assert_equal R::ATTEMPTS, result.reads
    assert_equal R::ATTEMPTS - 1, sleeps.size, "it sleeps BETWEEN reads, never after the last one"
    assert_equal 0, mints
    assert_includes result.out, "the last word",
      "the refusal must quote the failure it actually gave up on"
  end

  # --- the budget: a mint is granted a read, never charged one -------------

  test "[unit] a credential refusal on the FINAL attempt still gets its fresh-token read" do
    # attempts: 2 — both are spent on transient failures before the credential
    # fault appears, so under a budget that CHARGED the recovery the mint would be
    # made and never used. That is the defect this branch exists to prevent: a
    # token minted and discarded is worse than no recovery, because it looks like one.
    result, tokens, _sleeps, mints = run_policy(
      [[RESOLUTION_FAILURE, false], [CREDENTIAL_REFUSAL, false], ["35800673643", true]],
      attempts: 2
    )

    assert result.ok?, "the minted credential must actually be spent on a read"
    assert_equal 1, mints
    assert_equal 3, result.reads, "2 ambient reads + the granted recovery read"
    assert_equal [nil, nil, "ghs_fresh"], tokens
  end

  # --- the classifier this policy leans on ---------------------------------

  test "[unit] the measured 401 IS credential-shaped and the resolution failure is NOT" do
    # The split above is only as good as this classification, and both strings are
    # real gh output — so this pins the seam rather than restating the regex.
    assert Release::GhFailure.credential_failure?(CREDENTIAL_REFUSAL)
    assert_not Release::GhFailure.credential_failure?(RESOLUTION_FAILURE)
  end

  test "[unit] the policy composition loads and runs RAILS-FREE, as bin/release requires it" do
    # bin/release.rb is a plain Ruby script — it require_relative's these models
    # with NO Rails boot. Proven by EXECUTION in a bare ruby subprocess; a
    # Rails-dependent constant here would abort the sweep at the QA deploy.
    script = <<~RUBY
      require_relative "#{Rails.root.join('app/models/release/gh_failure')}"
      require_relative "#{Rails.root.join('app/models/release/gh_read_retry')}"
      reads = 0
      r = Release::GhReadRetry.call(sleeper: ->(_s) {}, minter: -> { "ghs_fresh" }) do |token|
        reads += 1
        token ? ["99", true] : [#{CREDENTIAL_REFUSAL.lines.first.strip.inspect}, false]
      end
      puts [r.ok?, r.cause, reads, r.token].join(",")
    RUBY
    out, status = Open3.capture2(SessionEnv.neutralized, "ruby", "-e", script)

    assert status.success?, "the retry policy must load standalone without Rails: #{out}"
    assert_equal "true,ok,2,ghs_fresh", out.strip
  end
end

require "test_helper"

# Pure reporting logic for a FAILED `gh` call. No shelling out here — bin/release
# gathers the captured output (sh → Open3.capture2e merges stderr into stdout) and
# this only decides what to SAY about it.
#
# The defect behind the module: the abort discarded that captured output and
# printed a fixed remedy instead, so a credential failure was reported as a PR
# problem and the advice ("open it by hand") would have failed identically.
class Release::GhFailureTest < ActiveSupport::TestCase
  G = Release::GhFailure

  # The EXACT sentence gh emitted during rel-20260812-3f1f9b, when the GitHub App
  # installation token had expired and gh fell back to the operator's fine-grained
  # PAT. Note it is 403-shaped, not 401 — which is why the cause was invisible
  # until the output was printed.
  INCIDENT_OUTPUT = "pull request create failed: GraphQL: Resource not accessible by " \
                    "personal access token (createPullRequest)".freeze

  FALLBACK = "Open it by hand (`gh pr create --base release --head accepted`), then re-run.".freeze

  # --- the captured output reaches the operator ----------------------------

  test "[unit] the abort text carries the captured gh output verbatim" do
    msg = G.abort_message(headline: "could not open the batch PR in mcritchie-studio.",
                          output: INCIDENT_OUTPUT, fallback: FALLBACK)

    assert_includes msg, INCIDENT_OUTPUT, "gh's own sentence is the whole point — it must survive"
    assert_includes msg, "gh said:", "and it is labelled as gh's words, not ours"
    assert_includes msg, "could not open the batch PR in mcritchie-studio.",
                    "the caller's headline still leads"
  end

  test "[unit] a multi-line gh output is quoted in full, every line indented" do
    out = "pull request create failed: GraphQL: Resource not accessible\nTry authenticating with:\n  gh auth login"
    msg = G.abort_message(headline: "boom", output: out, fallback: FALLBACK)

    out.lines.each { |line| assert_includes msg, line.chomp, "line dropped from the quote: #{line.chomp}" }
    assert_includes msg, "    Try authenticating with:", "quoted lines are indented under `gh said:`"
  end

  # An empty capture is REPORTED, not silently omitted: it tells the operator
  # there is no hidden detail to hunt for, and distinguishes a genuinely silent
  # failure from this being handed the wrong variable.
  test "[unit] an empty capture says so instead of quoting nothing" do
    msg = G.abort_message(headline: "boom", output: "", fallback: FALLBACK)

    assert_includes msg, "gh printed no output."
    refute_includes msg, "gh said:"
    assert_includes msg, FALLBACK, "with no output to classify, the caller's advice stands"
  end

  test "[unit] a nil capture is handled like an empty one" do
    assert_includes G.abort_message(headline: "boom", output: nil, fallback: FALLBACK),
                    "gh printed no output."
  end

  # --- a credential failure gets credential advice -------------------------

  test "[unit] the incident output advises re-minting the App token, NOT opening the PR by hand" do
    msg = G.abort_message(headline: "could not open the batch PR.",
                          output: INCIDENT_OUTPUT, fallback: FALLBACK)

    assert_includes msg, "CREDENTIAL failure", "it names the real class of failure"
    assert_includes msg, "bin/gh-app-git-credential", "it names the command that fixes it"
    assert_includes msg, "docs/agents/modules/credentials.md", "it points at the runbook"
    # The precise defect: the old advice would have failed identically.
    refute_includes msg, "Open it by hand",
                    "re-running the same command by hand uses the SAME broken credential"
    refute_includes msg, FALLBACK
  end

  test "[unit] every credential spelling classifies, and each one alone" do
    {
      "PAT fallback (403)" => INCIDENT_OUTPUT,
      "App token missing scope" => "Resource not accessible by integration (HTTP 403)",
      "revoked token" => "GraphQL: Bad credentials",
      "unauthenticated" => "gh: HTTP 401: Bad credentials",
      "gh's own remediation" => "Try authenticating with:  gh auth login",
      "requires auth" => "This endpoint requires authentication"
    }.each do |label, output|
      assert G.credential_failure?(output), "#{label} should classify as a credential failure"
    end
  end

  # --- RESTRAINT: the signature must not swallow unrelated failures --------
  #
  # A 403 is also how GitHub reports branch protection, rate limits, and a repo
  # you may not write. Telling the operator to re-mint a token on one of those
  # would be this module's own defect pointed at a different wrong remedy — so
  # these cases must keep the CALLER's advice.
  test "[unit] non-credential failures keep the caller's fallback advice" do
    [
      "pull request create failed: GraphQL: A pull request already exists for accepted.",
      "merge conflict between accepted and release; resolve on GitHub",
      "GraphQL: Changes must be made through a pull request. (branch protection)",
      "API rate limit exceeded for installation",
      "failed to run git: fatal: couldn't find remote ref accepted"
    ].each do |output|
      refute G.credential_failure?(output), "must NOT be classified as credential: #{output}"

      msg = G.abort_message(headline: "boom", output: output, fallback: FALLBACK)
      assert_includes msg, FALLBACK, "the caller's advice must stand for: #{output}"
      assert_includes msg, output, "and gh's words are printed either way"
      refute_includes msg, "CREDENTIAL failure"
    end
  end

  # The property, not one spelling: whatever the classification, gh's captured
  # words are ALWAYS in the abort. That is the invariant the finding asked for.
  test "[unit] the captured output survives regardless of classification" do
    [INCIDENT_OUTPUT, "some unrecognised gh explosion"].each do |output|
      assert_includes G.abort_message(headline: "boom", output: output, fallback: FALLBACK), output
    end
  end
end

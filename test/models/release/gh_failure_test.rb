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

  # The EXACT sentence gh emitted during rel-20260812-3f1f9b, when `GH_TOKEN` was
  # UNSET (measured at length 0) so gh fell back to the operator's fine-grained
  # PAT. Note it is 403-shaped, not 401 — which is why the cause was invisible
  # until the output was printed. An EXPIRED token is the other fault and does NOT
  # produce this: it is sent and rejected as 401 `Bad credentials`.
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

  # --- ONE remedy for every credential shape was the same defect, smaller ------
  #
  # Classifying correctly and then advising wrongly is not an improvement. Each
  # shape below has a DIFFERENT fix, and the default (re-mint) is actively a loop
  # for one of them.

  # `not accessible by integration` = the token is LIVE and the INSTALLATION lacks
  # the grant. Measured 2026-08-12 against both installations: mcritchie-agent has
  # pull_requests:write; mcritchie-deployer has NO pull_requests grant at all. And
  # bin/gh-app-git-credential reads GH_APP_ITEM, so re-minting under a leftover
  # ship-lane export mints the SAME powerless identity — forever.
  DEPLOYER_OUTPUT = "failed to create pull request: GraphQL: Resource not accessible by " \
                    "integration (createPullRequest)".freeze

  test "[unit] an installation-scope failure advises unset GH_APP_ITEM, never a bare re-mint" do
    msg = G.abort_message(headline: "gh pr create failed.", output: DEPLOYER_OUTPUT, fallback: FALLBACK)

    assert_includes msg, "unset GH_APP_ITEM", "the ONE remedy that breaks the loop"
    assert_includes msg, "RE-MINTING WILL NOT FIX",
                    "the default advice is wrong here and must be contradicted out loud"
    assert_includes msg, "github.mcritchie-deployer"
    assert_includes msg, "pull_requests"
    assert_includes msg, DEPLOYER_OUTPUT, "gh's words still lead"
  end

  # The string is GENERIC — an agent-identity token calling a user-scoped endpoint
  # returns it with nothing wrong with the identity — so the remedy must give the
  # operator a way to tell which case they are in, not assert the deployer.
  test "[unit] the installation-scope remedy names the discriminating check" do
    msg = G.abort_message(headline: "boom", output: DEPLOYER_OUTPUT, fallback: FALLBACK)

    assert_includes msg, "GH_APP_ITEM=${GH_APP_ITEM:-github.mcritchie-agent (default)}",
                    "the operator must be able to SEE which identity is selected"
    assert_includes msg, "already selected", "and be told the other reading exists"
  end

  # A private repo a token may not SEE is reported as one that does not EXIST.
  # Verified live 2026-08-12: `gh pr list --repo McRitchie-Studio/no-such-repo-xyz`
  # → "GraphQL: Could not resolve to a Repository with the name '…'. (repository)".
  MASKED_404 = "GraphQL: Could not resolve to a Repository with the name " \
               "'McRitchie-Studio/mcritchie-studio'. (repository)".freeze

  test "[unit] the 404 not-resolve shape classifies as a credential failure" do
    assert G.credential_failure?(MASKED_404),
           "GitHub masks an unreachable private repo as 404 — that is the shape a missing scope wears"
  end

  # RESTRAINT, applied to the shape most likely to be over-claimed: the identical
  # sentence is what a TYPO'd repo name returns, so the remedy leads with the check
  # that separates them instead of asserting the token is broken.
  test "[unit] the 404 remedy rules out the wrong repo name BEFORE blaming the token" do
    msg = G.abort_message(headline: "boom", output: MASKED_404, fallback: FALLBACK)

    assert_includes msg, "gh repo view", "one command discriminates the two readings"
    assert_includes msg, "Rule out the cheap cause first"
    assert_includes msg, "gh-app-git-credential", "and the re-mint follows, for the real case"
    refute_includes msg, "unset GH_APP_ITEM", "this is not the identity fault"
  end

  test "[unit] the default credential remedy still applies to the incident shape" do
    msg = G.abort_message(headline: "boom", output: INCIDENT_OUTPUT, fallback: FALLBACK)

    refute_includes msg, "RE-MINTING WILL NOT FIX", "re-minting is exactly what fixes this one"
    refute_includes msg, "gh repo view"
    assert_includes msg, "Re-mint the GitHub App installation token"
  end

  # --- the remedy must name the mechanism it actually observed ----------------
  #
  # The old text said installation tokens "expire hourly. When one does, `gh` can
  # fall back to a fine-grained PAT" — which is not how it works, and sends the
  # operator hunting a permissions problem when the real fault is an env var.
  test "[unit] the remedy separates the 401 (expired) and 403 (unset) mechanisms" do
    msg = G.abort_message(headline: "boom", output: INCIDENT_OUTPUT, fallback: FALLBACK)

    assert_includes msg, "401 `Bad credentials`", "an EXPIRED token is sent and rejected"
    assert_includes msg, "UNSET or EMPTY", "a token that is never sent is what triggers the PAT fallback"
    assert_includes msg, "different mechanism"
    refute_includes msg, "expire hourly. When one does",
                    "the retired sentence attributed the PAT fallback to expiry"
  end

  # --- the remedy has to be RUNNABLE from where bin/release runs ---------------
  #
  # A relative `bin/…` is a command that works from one directory. bin/release is
  # normally launched BY absolute path, so the remedy the operator copies would
  # have failed on the cwd — a wrong remedy printed by the module written to stop
  # printing wrong remedies.
  test "[unit] the re-mint command carries an ABSOLUTE path to the helper" do
    msg = G.abort_message(headline: "boom", output: INCIDENT_OUTPUT, fallback: FALLBACK)
    helper = G::GH_CREDENTIAL_HELPER

    assert helper.start_with?("/"), "an absolute path, or the remedy depends on the operator's cwd"
    assert helper.end_with?("/bin/gh-app-git-credential")
    assert_includes msg, helper
    refute_match(/(?<![\w\/])bin\/gh-app-git-credential/, msg,
                 "no bare relative spelling may survive anywhere in the remedy")
  end

  # And it must point at a file that EXISTS in this checkout — the path is derived
  # from __dir__, so a file move breaks it silently otherwise.
  test "[unit] the helper path resolves to a real executable in this checkout" do
    assert File.executable?(G::GH_CREDENTIAL_HELPER),
           "the remedy names #{G::GH_CREDENTIAL_HELPER}, which is not an executable file"
  end

  # --- the recovery path quotes gh too ----------------------------------------
  #
  # THE FINDING: bin/release echoed gh's words with `say(out) if ok`, ABOVE the
  # `pr_merged?` fallback that sets `ok = true`. On the interrupted-run recovery
  # `ok` was still false when the echo was evaluated, so the ONE path where gh's
  # output is the EVIDENCE for continuing printed nothing — this module's thesis
  # failing to apply to itself, on one path.
  test "[unit] the recovery message quotes gh, under the recovery headline" do
    out = "failed to merge: Pull request McRitchie-Studio/mcritchie-studio#811 is already merged"
    msg = G.recovery_message(headline: "  ↷ https://…/811 already merged (interrupted prior run)",
                             output: out)

    assert_includes msg, out, "gh's words are the evidence the fallback acted on"
    assert_includes msg, "gh said:", "and they are LABELLED — failure text on a surviving run reads as success"
    assert msg.start_with?("  ↷ "), "the headline leads, the quote follows"
  end

  test "[unit] a silent recovery says so rather than printing a bare headline" do
    msg = G.recovery_message(headline: "  ↷ already merged", output: "")

    assert_includes msg, "gh printed no output.",
                    "same rule as the abort path: an empty capture is itself information"
  end
end

class Release
  # Pure decision logic for REPORTING A FAILED `gh` CALL — IO-free and Rails-free,
  # the same contract as CleanCheck / MergePlan / ShipSequence (bin/release
  # `require_relative`s this file directly, so it must load standalone).
  #
  # WHY IT EXISTS. bin/release runs `gh` through `sh(..., capture: true)`, and that
  # helper uses `Open3.capture2e` — stderr is MERGED INTO the captured stdout. So
  # whenever a `gh` call fails, the reason is already sitting in a local variable.
  # The aborts used to DISCARD it and print a fixed remedy instead.
  #
  # During rel-20260812-3f1f9b the `accepted → release` batch PR failed because
  # `GH_TOKEN` was UNSET (measured at length 0), so `gh` fell back to the stored
  # personal access token, which lacks the scope. gh said exactly what was wrong:
  #
  #   pull request create failed: GraphQL: Resource not accessible by personal
  #   access token (createPullRequest)
  #
  # The abort threw that sentence away and advised "open it by hand (`gh pr create
  # --base release --head accepted`)". That advice was WORSE than useless: the
  # hand-run command uses the SAME broken credential and fails identically. The
  # operator lost the recovery to a remedy the tool already knew was wrong — and
  # the 403 shape (not a 401) is precisely what makes the credential cause
  # invisible unless you read gh's own words.
  #
  # TWO MECHANISMS, ONE REMEDY, DIFFERENT SIGNATURES — and this file used to
  # conflate them ("the token expired and gh fell back to a PAT"). Both occurred
  # during that release, an hour apart, and only one of them is a fallback:
  #   * `GH_TOKEN` UNSET or EMPTY — nothing is sent, `gh` falls back to the stored
  #     PAT, and the PAT's missing scope reads as 403 `not accessible by personal
  #     access token`.
  #   * `GH_TOKEN` SET but EXPIRED — it IS sent and rejected outright: 401 `Bad
  #     credentials`. No fallback happens; an expired token never produces the 403.
  # Re-minting fixes both. Saying WHICH one occurred is what makes the sentence
  # worth printing.
  #
  # THE RULE: print what the tool said, THEN advise from what it said.
  module GhFailure
    module_function

    # A CREDENTIAL-class failure: the remedy is a token, never a retry of the same
    # command by hand.
    #
    # The spellings are ENUMERATED rather than broadened to something like
    # /HTTP 40[13]/, and that restraint is the point. A 403 is also how GitHub
    # reports branch protection, a rate limit, and a repo you simply may not write.
    # Advising "re-mint your token" on one of those would be this module's own
    # defect pointed at a different wrong remedy — so an unrecognised failure keeps
    # the caller's ordinary advice and the operator still gets gh's raw words.
    CREDENTIAL_SIGNATURE = /
      not\ accessible\ by\ personal\ access\ token  # GH_TOKEN unset or empty → gh fell back to a PAT
      | not\ accessible\ by\ integration            # App token live, the INSTALLATION lacks the grant
      | Could\ not\ resolve\ to\ a\ Repository      # GitHub masks an unreachable private repo as 404
      | Bad\ credentials                            # token invalid, revoked, expired, or malformed
      | HTTP\ 401                                   # unauthenticated outright
      | requires\ authentication
      | gh\ auth\ login                             # gh's own remediation line
    /xi

    # The git credential helper, ABSOLUTE-pathed. A relative `bin/…` in an
    # operator-facing remedy is a command that only works from one directory, and
    # bin/release is normally launched BY absolute path from wherever the agent
    # happens to stand. Derived from this file's own location, so it names the
    # checkout that is actually running (a worktree included) instead of a
    # hard-coded home directory. File.expand_path is pure string math — it touches
    # no filesystem, so the IO-free contract holds.
    GH_CREDENTIAL_HELPER = File.expand_path("../../../bin/gh-app-git-credential", __dir__).freeze

    # ONE canonical re-mint recipe, shared by every remedy below and matching
    # docs/agents/modules/credentials.md. It honours GH_APP_ITEM (so it mints the
    # identity the lane selected) and discovers the `.pem` attachment by suffix,
    # so no key filename is baked in to rot at the next rotation.
    REMINT_COMMAND =
      "export GH_TOKEN=$(printf 'protocol=https\\nhost=github.com\\n\\n' | " \
      "#{GH_CREDENTIAL_HELPER} get | sed -n 's/^password=//p')".freeze

    # The DEFAULT credential remedy: the token is absent, expired, or revoked, and
    # a fresh one fixes it. Names WHICH mechanism produced WHICH status code —
    # they are different faults that happen to share a fix, and collapsing them is
    # how an operator reads a 403 and goes hunting for a permissions problem.
    CREDENTIAL_REMEDY =
      "This is a CREDENTIAL failure, not a PR problem — re-running the same command by hand uses " \
      "the SAME broken credential and fails identically. Re-mint the GitHub App installation " \
      "token:\n" \
      "      #{REMINT_COMMAND}\n" \
      "    then re-run; it resumes. (Installation tokens live 1 hour, and the two faults look " \
      "DIFFERENT: an EXPIRED GH_TOKEN is sent and rejected — 401 `Bad credentials`. An UNSET or " \
      "EMPTY GH_TOKEN is never sent, so `gh` falls back to the stored personal access token and " \
      "its missing scope reads as 403 `not accessible by personal access token`. Same remedy, " \
      "different mechanism. See docs/agents/modules/credentials.md.)"

    # `not accessible by integration` is the ONE credential shape re-minting cannot
    # fix, so it must not be given the re-mint advice: the installation token is
    # LIVE and the INSTALLATION lacks the grant, so a fresh token for the same
    # identity fails identically — the very loop this module exists to stop, one
    # identity over. Measured 2026-08-12 against both installations:
    #   github.mcritchie-agent    → pull_requests: write
    #   github.mcritchie-deployer → NO pull_requests grant at all
    # and bin/gh-app-git-credential:34 reads GH_APP_ITEM, so a ship-lane export
    # left in the environment re-mints the deployer every time.
    #
    # The string is GENERIC, though, and the remedy says so rather than assuming
    # the deployer: an agent-identity token calling a user-scoped endpoint returns
    # this same sentence with nothing wrong with the identity at all.
    INSTALLATION_SCOPE_REMEDY =
      "This is a CREDENTIAL failure that RE-MINTING WILL NOT FIX — `not accessible by " \
      "integration` means the installation token is live and the INSTALLATION lacks the " \
      "permission, so a fresh token for the same identity fails identically. Check which " \
      "identity is selected:\n" \
      "      echo \"GH_APP_ITEM=${GH_APP_ITEM:-github.mcritchie-agent (default)}\"\n" \
      "    The ship identity `github.mcritchie-deployer` carries NO `pull_requests` grant by " \
      "design and can never open or merge a PR. If it is selected, `unset GH_APP_ITEM`, re-mint, " \
      "and re-run so this lane rides `github.mcritchie-agent` (pull_requests: write):\n" \
      "      unset GH_APP_ITEM && #{REMINT_COMMAND}\n" \
      "    The sweep lane must never export GH_APP_ITEM — see " \
      "docs/agents/agents/avi/sops/qa-release.md. If the agent identity was already selected, " \
      "the App's org permissions need widening instead. See docs/agents/modules/credentials.md."

    # A 404 that is USUALLY a credential fault. GitHub deliberately reports a
    # private resource a token may not see as "does not exist" rather than
    # "forbidden", so a scope-missing token reads as a typo — which is exactly
    # what makes it worth classifying, and exactly why the remedy must NOT open by
    # asserting the token is broken. Rule out the cheap cause first; the check is
    # one command and it discriminates the two readings outright.
    MASKED_REPO_REMEDY =
      "This is a 404 that USUALLY means a credential fault: GitHub reports a repo a token may " \
      "not SEE as one that does not exist, so a missing scope arrives wearing a typo's clothes. " \
      "Rule out the cheap cause first — a wrong `owner/name` in the release registry:\n" \
      "      gh repo view <owner>/<name> --json name\n" \
      "    If that also 404s for a repo you know exists, the token cannot reach it. Re-mint:\n" \
      "      #{REMINT_COMMAND}\n" \
      "    then re-run; it resumes. See docs/agents/modules/credentials.md."

    def credential_failure?(output)
      CREDENTIAL_SIGNATURE.match?(output.to_s)
    end

    # WHICH credential remedy this output supports. One remedy for every
    # credential shape was the smaller version of this module's own defect: it
    # advised a re-mint on the one shape a re-mint cannot fix (`not accessible by
    # integration`), sending the operator around the same loop with a fresh token.
    # Most specific spelling wins.
    def credential_remedy(output)
      text = output.to_s
      return INSTALLATION_SCOPE_REMEDY if /not accessible by integration/i.match?(text)
      return MASKED_REPO_REMEDY if /Could not resolve to a Repository/i.match?(text)

      CREDENTIAL_REMEDY
    end

    # The abort text for a failed `gh` call: what we were doing, WHAT GH SAID, and
    # the remedy the output actually supports.
    #
    #   headline: what failed, in the caller's words (repo, branches, PR URL).
    #   output:   the captured combined stdout+stderr from `sh(..., capture: true)`.
    #   fallback: the remedy when the failure is NOT credential-shaped.
    def abort_message(headline:, output:, fallback:)
      lines = [headline]
      lines.concat(quoted_output(output))
      lines << "  → #{credential_failure?(output) ? credential_remedy(output) : fallback}"
      lines.join("\n")
    end

    # The same thesis on the path that is NOT an abort: a `gh` call FAILED and a
    # fallback RESCUED it, so the run continues. gh's words matter more here than
    # anywhere, because they are the EVIDENCE the fallback acted on ("Pull request
    # #811 is already merged" is why treating it as promoted is correct).
    #
    # THE DEFECT THIS EXISTS FOR. bin/release echoed gh's output with `say(out) if
    # ok` placed ABOVE the `pr_merged?` fallback that sets `ok = true`. `ok` was
    # still false when the echo was evaluated, so the one path that most needed
    # gh's words was the one path that discarded them — this module's own thesis
    # failing to apply to itself. An ordering rule buried in a 6,600-line script
    # is not a decision any test can hold; a function of its inputs is.
    #
    # The output is QUOTED (the same "gh said:" framing as an abort) rather than
    # echoed bare: this text is a FAILURE message printed on a surviving run, and
    # unlabelled failure text following a step that continued reads as success.
    def recovery_message(headline:, output:)
      [headline, *quoted_output(output)].join("\n")
    end

    # gh's own words, indented and labelled. An EMPTY capture is reported as such
    # rather than silently omitted: "gh printed nothing" is itself information. It
    # tells the operator there is no hidden detail to hunt for — and distinguishes
    # a genuinely silent failure from this module being handed the wrong variable.
    def quoted_output(output)
      text = output.to_s.strip
      return ["  gh printed no output."] if text.empty?

      ["  gh said:", *text.lines.map { |line| "    #{line.chomp}" }]
    end
  end
end

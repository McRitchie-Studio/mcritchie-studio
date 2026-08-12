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
  # During rel-20260812-3f1f9b the `accepted → release` batch PR failed because the
  # GitHub App installation token had expired and `gh` silently fell back to the
  # operator's fine-grained PAT. gh said exactly what was wrong:
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
      not\ accessible\ by\ personal\ access\ token  # App token expired → gh fell back to a PAT
      | not\ accessible\ by\ integration            # App token live, missing the permission
      | Bad\ credentials                            # token invalid, revoked, or malformed
      | HTTP\ 401                                   # unauthenticated outright
      | requires\ authentication
      | gh\ auth\ login                             # gh's own remediation line
    /xi

    CREDENTIAL_REMEDY =
      "This is a CREDENTIAL failure, not a PR problem — re-running the same command by hand uses " \
      "the SAME broken credential and fails identically. Re-mint the GitHub App installation " \
      "token:\n" \
      "      export GH_TOKEN=$(printf 'protocol=https\\nhost=github.com\\n\\n' | " \
      "bin/gh-app-git-credential get | sed -n 's/^password=//p')\n" \
      "    then re-run; it resumes. (App installation tokens expire hourly. When one does, `gh` " \
      "can fall back to a fine-grained PAT that lacks the scope — which is why this reads as a " \
      "403 rather than a 401. See docs/agents/modules/credentials.md.)"

    def credential_failure?(output)
      CREDENTIAL_SIGNATURE.match?(output.to_s)
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
      lines << "  → #{credential_failure?(output) ? CREDENTIAL_REMEDY : fallback}"
      lines.join("\n")
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

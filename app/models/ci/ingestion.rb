# frozen_string_literal: true

module Ci
  # WHICH REGISTERED REPOS ACTUALLY DELIVER Actions runs to the board.
  #
  # The board's CI verdict is DB-NATIVE: Ci::ReviewGate folds ingested
  # GithubWorkflowRun rows and never makes a live `gh` call. A repo whose Actions
  # webhook was never wired to `POST /api/v1/github/webhook` is therefore
  # permanently CI-INVISIBLE here, however green GitHub is.
  #
  # AND THE FAILURE IS SILENT, which is the whole reason this module exists. An
  # unwired repo's task reads :none — INDISTINGUISHABLE from "CI has not run
  # yet" — so `Task.claim_next_review` (green-CI only) never pops it, no reviewer
  # claims it, and nothing bounces it either. It just sits in `submitted`.
  # Measured twice on mcritchie-industries: PR #17 (2026-08-08) and PR #36
  # (2026-08-13) were both 4/4 green on GitHub and unclaimable on the board.
  #
  # Absence of rows is precisely the kind of gap a suite never notices on its
  # own, so it is asked as a QUESTION here — and asked OVER THE REGISTRY
  # (config/release_repos.yml), never over a hand-written repo list, so the next
  # satellite onboarded is covered the day it lands instead of the day someone
  # remembers to add it. test/models/ci/ingestion_test.rb drives every registered
  # repo in turn and asserts the guard names the one whose rows are missing.
  #
  # OWNER-AGNOSTIC by design: the table stores full names, and the legacy
  # `amcritchie/*` rows sit beside the current `McRitchie-Studio/*` ones for the
  # same repos. A repo that delivered under its old owner IS delivering, so the
  # match is on the repo SLUG, not the full name.
  module Ingestion
    module_function

    # The repos that MUST deliver runs: the conductor's three-rung set, minus any
    # repo that DECLARES it ships no suite workflow.
    #
    # The exemption is derived, not re-spelled: GithubWorkflowRun.ci_workflow_for
    # is the one place a repo's CI workflow is decided, and a nil there is an
    # explicit declaration (solana-studio ships no workflow at all — it has no
    # .github/workflows directory). A repo with no suite workflow cannot deliver
    # suite runs, and Ci::ReviewGate already fails it closed at :none, so listing
    # it here would be noise that trains a reader to ignore the guard.
    def expected_repos(config = Release::Repos.config)
      Release::Ladder.sweepable(config).select { |repo| GithubWorkflowRun.ci_workflow_for(repo).present? }
    end

    # The repos among `repos` the board holds NO ingested run for — the unwired
    # set. Pass the repos you care about (the pop passes the repos of the tasks it
    # just skipped); the default asks the whole registry.
    def unwired(repos = expected_repos, scope: GithubWorkflowRun.all)
      seen = ingested_slugs(scope)
      Array(repos).map { |repo| repo.to_s.strip }.reject(&:empty?).uniq
                  .reject { |repo| seen.include?(slug_of(repo)) }
    end

    # Does the board hold ANY ingested run for this repo? Any workflow, any
    # branch, any age — the question is whether deliveries arrive at all, not
    # whether a particular tree is green (that is Ci::ReviewGate's).
    def ingested?(repo, scope: GithubWorkflowRun.all)
      unwired([repo], scope: scope).empty?
    end

    # Every repo SLUG the board has ever ingested a run for. One DISTINCT read,
    # then slugged — see the owner-agnostic note above.
    def ingested_slugs(scope = GithubWorkflowRun.all)
      scope.distinct.pluck(:repo).filter_map { |full_name| slug_of(full_name) }.uniq
    end

    # "McRitchie-Studio/turf-monster" and "turf-monster" both slug to
    # "turf-monster"; blank/garbage slugs to nil so they never match.
    def slug_of(repo)
      repo.to_s.split("/").last.to_s.strip.presence
    end
  end
end

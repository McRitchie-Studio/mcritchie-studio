# frozen_string_literal: true

require "test_helper"

module Ci
  # [unit] THE ABSENCE DETECTOR. The board's CI verdict is DB-native, so a
  # registered repo whose Actions webhook was never wired delivers nothing, reads
  # :none, and its submitted task is never popped for review — a silent strand,
  # not a visible failure. Nothing in the suite noticed that, twice, because
  # NOTHING FAILS WHEN A ROW IS SIMPLY ABSENT.
  #
  # These drive the guard over the REGISTRY, one repo at a time, so the assertion
  # is about the PROPERTY ("a registered repo with no ingested runs is named"),
  # not about mcritchie-industries — the repo that happened to expose it. Register
  # a new three-rung satellite tomorrow and it is covered here the same day.
  class IngestionTest < ActiveSupport::TestCase
    setup do
      GithubWorkflowRun.delete_all
      @run_id = 0
    end

    test "[unit] the guard names a registered repo with no ingested runs" do
      repos = Ci::Ingestion.expected_repos
      assert_operator repos.length, :>=, 3, "the registry parsed to almost nothing — the guard would check nothing"

      repos.each do |unwired_repo|
        GithubWorkflowRun.delete_all
        (repos - [unwired_repo]).each { |repo| ingest(repo) }

        assert_equal [unwired_repo], Ci::Ingestion.unwired,
                     "#{unwired_repo} has no ingested workflow runs, so the board can never read its CI as " \
                     "green and pr-review can never claim its PRs — the guard must name it"
      end
    end

    test "[unit] the guard is quiet once every registered repo delivers" do
      Ci::Ingestion.expected_repos.each { |repo| ingest(repo) }

      assert_empty Ci::Ingestion.unwired,
                   "every registered repo has ingested runs — a guard that still complains would be ignored"
    end

    test "[unit] a repo that delivered under its LEGACY owner counts as wired" do
      # The table stores full names and the 2026-07-29 org migration left
      # `amcritchie/*` rows beside the `McRitchie-Studio/*` ones. Matching the
      # full name would report a delivering repo as unwired.
      repo = Ci::Ingestion.expected_repos.first
      ingest(repo, nwo: "amcritchie/#{repo}")

      assert Ci::Ingestion.ingested?(repo), "a legacy-owner row is still a delivery from that repo"
      assert_not_includes Ci::Ingestion.unwired, repo
    end

    test "[unit] only the asked-about repos are judged" do
      # The review pop asks about the repos of the tasks it just skipped, which is
      # NOT the registry — an unregistered repo it asks about must still be
      # judged, and a registered repo it did not ask about must not be dragged in.
      assert_equal ["not-a-registered-repo"], Ci::Ingestion.unwired(["not-a-registered-repo"])

      ingest("not-a-registered-repo")
      assert_empty Ci::Ingestion.unwired(["not-a-registered-repo"])
    end

    test "[unit] every exempted repo has DECLARED that it ships no suite workflow" do
      # The exemption is derived from GithubWorkflowRun.ci_workflow_for — the one
      # place a repo's CI workflow is decided — so it cannot become a quiet
      # dumping ground. A repo that ships a suite can never be exempt.
      exempt = Release::Ladder.sweepable(Release::Repos.config) - Ci::Ingestion.expected_repos

      exempt.each do |repo|
        assert_nil GithubWorkflowRun.ci_workflow_for(repo),
                   "#{repo} is exempt from the ingestion guard but declares a CI workflow — it must deliver runs"
      end
    end

    test "[unit] the expected set is the three-rung set, not every registry entry" do
      # A `planned` / `dormant` / `blocked` repo has no pipeline to be blind in;
      # holding it to this guard would make the guard permanently red.
      parked = Release::Ladder.parked(Release::Repos.config).keys

      assert_empty (Ci::Ingestion.expected_repos & parked),
                   "a parked repo is not swept, so it is not expected to deliver CI"
    end

    private

    def ingest(repo, nwo: Ci::ReviewGate.nwo_for(repo))
      @run_id += 1
      GithubWorkflowRun.create!(
        repo: nwo, run_id: @run_id, status: "completed", conclusion: "success",
        workflow_name: GithubWorkflowRun.ci_workflow_for(repo) || GithubWorkflowRun::CI_WORKFLOW,
        head_branch: "release", head_sha: "sha-#{@run_id}", run_started_at: Time.current
      )
    end
  end
end

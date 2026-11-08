# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../support/fake_task_derivation"
require_relative "../../lib/seam_reconcile"

# The board refreshes its own `merged` cache (devops-v3 piece 4c-i): nobody stamps
# it. TaskMergedRungRefreshJob does the write; a merged `pull_request` webhook finds
# the task(s) the PR belongs to and runs it. GitHub is FakeTaskDerivation throughout,
# handed in through Github::TaskDerivation.new, which is what the job builds.
class TaskMergedRungRefreshJobTest < ActiveJob::TestCase
  HUB = "mcritchie-studio"
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/777"
  SECRET = "test-webhook-secret-do-not-use-in-prod"

  def task(stage: "reviewed", merged: nil, devops: {})
    Task.create!(title: "merged refresh sample task", stage: stage, merged: merged,
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB] }.merge(devops) })
  end

  def pull_request_event(action: "closed", merged: true, url: PR_URL, branch: "feat/unrelated")
    { "action" => action,
      "pull_request" => { "html_url" => url, "merged" => merged, "head" => { "ref" => branch } },
      "repository" => { "full_name" => "McRitchie-Studio/#{HUB}" } }
  end

  def with_github(fake, &block)
    Github::TaskDerivation.stub(:new, fake, &block)
  end

  test "[unit] the job writes the derived rung into a blank merged column" do
    t = task(devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      TaskMergedRungRefreshJob.perform_now(t.slug)
    end

    assert_equal "accepted", t.reload.merged
  end

  test "[unit] the job swallows a failure into ErrorLog and leaves the column alone" do
    t = task(merged: "accepted", devops: { "pr_url" => PR_URL })
    boom = Object.new
    def boom.merged_rung(_url) = raise(ArgumentError, "boom")

    with_github(boom) { TaskMergedRungRefreshJob.perform_now(t.slug) }

    assert_equal "accepted", t.reload.merged
    log = ErrorLog.order(:id).last
    assert_equal ["Task", t.id], [log.target_type, log.target_id], "the ErrorLog must be findable by its task"
  end

  test "[unit] a missing task is a no-op" do
    assert_nil TaskMergedRungRefreshJob.perform_now("no-such-task-slug")
  end

  test "[integration] a merged pull_request webhook refreshes the task that recorded the PR" do
    t = task(devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end

    assert_equal "accepted", t.reload.merged, "the webhook refreshes merged; nobody stamped it"
  end

  test "[integration] the webhook finds an unrecorded task by its feat/<slug> branch and by pr_urls" do
    by_branch = task
    turf_url = "https://github.com/McRitchie-Studio/turf-monster/pull/88"
    by_map = task(devops: { "repositories" => [HUB, "turf-monster"], "pr_url" => PR_URL.sub("777", "778"),
                            "pr_urls" => { "turf-monster" => turf_url } })
    fake = FakeTaskDerivation.new(
      branches: { [HUB, "feat/#{by_branch.slug}"] => PR_URL },
      rungs: { PR_URL => "accepted", turf_url => "accepted", PR_URL.sub("777", "778") => "accepted" }
    )

    with_github(fake) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(branch: "feat/#{by_branch.slug}"))
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(url: turf_url))
    end

    assert_equal "accepted", by_branch.reload.merged
    assert_equal "accepted", by_map.reload.merged
  end

  # The lookup reads the indexed columns, not the jsonb path: the keys are stripped
  # from the stored metadata, so only a column can match.
  test "[integration] the webhook finds the task by its pr_url and branch columns" do
    by_url = task(devops: { "pr_url" => PR_URL })
    by_branch = task(devops: { "branch" => "agent/custom-branch" })
    [by_url, by_branch].each do |t|
      t.update_columns(metadata: { "devops" => t.devops.except("pr_url", "branch") }) # rubocop:disable Rails/SkipsModelValidations
    end

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end

    assert_equal "accepted", by_url.reload.merged, "found by the pr_url column alone"
    found = GithubWorkflowRunIngestJob.new.send(:tasks_for_pull_request, nil, "agent/custom-branch")
    assert_equal [by_branch.id], found.map(&:id), "found by the branch column alone"
  end

  test "[unit] an unmerged close, or any other action, refreshes nothing" do
    t = task(devops: { "pr_url" => PR_URL })
    fake = FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })

    with_github(fake) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(merged: false))
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(action: "opened", merged: false))
    end

    assert_nil t.reload.merged
    assert_empty fake.calls, "no GitHub read for a PR that did not merge"
  end

  # ── stage-follows-github: the stage follows the merge ─────────────────────
  # A merged PR used to refresh only `merged`; the task sat `submitted` until
  # devops-reconcile healed the stamp_lost class (engine-loader-family: 19.5 h).

  def merge_transitions(t)
    t.task_events.transitions.where(from_stage: "submitted", to_stage: "reviewed")
  end

  test "[unit] a merged own PR moves a submitted task to reviewed with the merge stamp" do
    t = task(stage: "submitted", devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end

    t.reload
    assert_equal %w[reviewed accepted], [t.stage, t.merged]
    event = merge_transitions(t).sole
    assert_equal TaskEvent::GITHUB_SOURCE, event.source
    assert_equal TaskEvent::SYSTEM_ACTOR, event.actor, "no open review intent: the system placeholder"
  end

  test "[unit] the move is attributed to the reviewer whose open intent the merge completes" do
    t = task(stage: "submitted", devops: { "pr_url" => PR_URL })
    t.record_intent_event(to_stage: "reviewed", actor: "carl", reviewers: [{ "slug" => "carl", "weight" => "primary" }])

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end

    event = merge_transitions(t.reload).sole
    assert_equal "carl", event.actor
    assert_equal [{ "slug" => "carl", "weight" => "primary" }], event.metadata["reviewers"]
  end

  test "[unit] only from submitted: a building or reviewed task keeps its stage" do
    building = task(stage: "building", devops: { "pr_url" => PR_URL })
    reviewed = task(stage: "reviewed", devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end

    assert_equal "building", building.reload.stage, "a building task is not under review; the stage holds"
    assert_equal "accepted", building.merged, "the merged cache still refreshes"
    assert_equal "reviewed", reviewed.reload.stage
    assert_empty merge_transitions(reviewed)
  end

  test "[unit] only for the task's own PR: a PR matched by branch in another repo moves nothing" do
    t = task(stage: "submitted", devops: { "pr_url" => PR_URL })
    other = "https://github.com/McRitchie-Studio/turf-monster/pull/88"

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted", other => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(url: other, branch: "feat/#{t.slug}"))
    end

    assert_equal "submitted", t.reload.stage, "turf-monster#88 is not one of this task's PRs"
  end

  test "[unit] a multi-repo task waits until every repo has merged" do
    sibling = "https://github.com/McRitchie-Studio/turf-monster/pull/89"
    t = task(stage: "submitted", devops: { "repositories" => [HUB, "turf-monster"], "pr_url" => PR_URL,
                                           "pr_urls" => { "turf-monster" => sibling } })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted", sibling => nil })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end
    assert_equal "submitted", t.reload.stage, "the sibling PR is still open"

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted", sibling => "accepted" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(url: sibling))
    end
    assert_equal %w[reviewed accepted], [t.reload.stage, t.merged]
  end

  test "[unit] only a merge onto accepted moves it: a stacked-parent merge or another rung holds" do
    stacked = task(stage: "submitted", devops: { "pr_url" => PR_URL })
    other = PR_URL.sub("777", "779")
    past = task(stage: "submitted", devops: { "pr_url" => other })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => nil, other => "release" })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event(url: other))
    end

    assert_equal "submitted", stacked.reload.stage, "merged into a parent branch: on no rung yet"
    assert_equal "submitted", past.reload.stage, "not the accepted rung the review path lands on"
  end

  test "[unit] an unreadable GitHub moves nothing" do
    t = task(stage: "submitted", devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => :unreadable })) do
      GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event)
    end

    assert_equal "submitted", t.reload.stage
    assert_nil t.merged
  end

  test "[unit] a re-delivered merge event is idempotent: one transition" do
    t = task(stage: "submitted", devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      2.times { GithubWorkflowRunIngestJob.perform_now("pull_request", pull_request_event) }
    end

    assert_equal "reviewed", t.reload.stage
    assert_equal 1, merge_transitions(t).count
  end

  test "[unit] the refresh job alone, without a PR url, never moves the stage" do
    t = task(stage: "submitted", devops: { "pr_url" => PR_URL })

    with_github(FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      TaskMergedRungRefreshJob.perform_now(t.slug)
    end

    assert_equal %w[submitted accepted], [t.reload.stage, t.merged]
  end
end

# [integration] The same path end to end through the signed receiver.
class GithubPullRequestWebhookTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = TaskMergedRungRefreshJobTest::SECRET
  PR_URL = TaskMergedRungRefreshJobTest::PR_URL

  setup do
    @prev_secret = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = SECRET
  end

  teardown do
    @prev_secret.nil? ? ENV.delete("GITHUB_WEBHOOK_SECRET") : ENV["GITHUB_WEBHOOK_SECRET"] = @prev_secret
  end

  test "[integration] a signed merged-PR delivery refreshes the merged column" do
    t = Task.create!(title: "merged webhook sample task", stage: "reviewed",
                     metadata: { "devops" => { "shape" => "backend", "repositories" => ["mcritchie-studio"],
                                               "pr_url" => PR_URL } })
    body = JSON.generate("action" => "closed",
                         "pull_request" => { "html_url" => PR_URL, "merged" => true, "head" => { "ref" => "feat/x" } })
    headers = { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request",
                "X-Hub-Signature-256" => "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)}" }

    Github::TaskDerivation.stub(:new, FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      perform_enqueued_jobs { post "/api/v1/github/webhook", params: body, headers: headers }
    end

    assert_response :ok
    assert_equal "accepted", t.reload.merged
  end

  # stage-follows-github: merged and stage land together, so the pr-review seam
  # reconcile has no stamp_lost to find on a fresh merge.
  test "[integration] a signed merged-PR delivery moves submitted to reviewed and leaves no stamp_lost" do
    t = Task.create!(title: "stage follows github sample task", stage: "submitted",
                     metadata: { "devops" => { "shape" => "backend", "repositories" => ["mcritchie-studio"],
                                               "pr_url" => PR_URL } })
    before = SeamReconcile.classify({ "slug" => t.slug, "stage" => t.stage },
                                    pr_state: :merged, merged_state: :unset)
    assert_equal :stamp_lost, before&.anomaly, "precondition: the old board state reads as stamp_lost"

    body = JSON.generate("action" => "closed",
                         "pull_request" => { "html_url" => PR_URL, "merged" => true, "head" => { "ref" => "feat/x" } })
    headers = { "Content-Type" => "application/json", "X-GitHub-Event" => "pull_request",
                "X-Hub-Signature-256" => "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)}" }

    Github::TaskDerivation.stub(:new, FakeTaskDerivation.new(rungs: { PR_URL => "accepted" })) do
      perform_enqueued_jobs { post "/api/v1/github/webhook", params: body, headers: headers }
    end

    assert_response :ok
    t.reload
    assert_equal %w[reviewed accepted], [t.stage, t.merged]
    after = SeamReconcile.classify({ "slug" => t.slug, "stage" => t.stage },
                                   pr_state: :merged, merged_state: :set, merged_value: t.merged)
    assert_nil after, "no pr-review seam anomaly after a fresh merge"

    # The race with pr-review: its own `bin/task move reviewed` lands after the
    # webhook. A same-stage move is a confirming no-op, never a refusal.
    auth = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }
    patch "/api/v1/tasks/#{t.slug}", params: { stage: "reviewed", event: { source: "cli", actor: "avi" } },
                                     headers: auth, as: :json
    assert_response :ok
    assert_equal 1, t.task_events.transitions.where(from_stage: "submitted", to_stage: "reviewed").count
  end
end

# The background half of tasks#show (task-show-never-waits-github): the request
# serves the stamp and queues this job, which derives and caches a blank pr_url.
class TaskPrUrlCacheJobTest < ActiveJob::TestCase
  HUB = "mcritchie-studio"
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/991"

  def task(stage: "building", devops: {})
    Task.create!(title: "pr url cache sample task", stage: stage,
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB] }.merge(devops) })
  end

  test "[unit] the job caches the derived PR url into a blank column" do
    t = task
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => PR_URL })

    TaskPrUrlCacheJob.perform_now(t.slug, derivation: fake)

    assert_equal PR_URL, t.reload.devops_url("pr")
  end

  test "[unit] an unreadable GitHub leaves the column blank and raises nothing" do
    t = task
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => :unreadable })

    TaskPrUrlCacheJob.perform_now(t.slug, derivation: fake)

    assert_nil t.reload.devops_url("pr")
  end

  test "[unit] a failure is swallowed into an ErrorLog that targets the task" do
    t = task
    boom = Object.new
    def boom.pr_url_for_branch(*, **) = raise(ArgumentError, "boom")

    TaskPrUrlCacheJob.perform_now(t.slug, derivation: boom)

    log = ErrorLog.order(:id).last
    assert_equal ["Task", t.id], [log.target_type, log.target_id]
  end

  test "[unit] a missing task is a no-op" do
    assert_nil TaskPrUrlCacheJob.perform_now("no-such-task-slug")
  end
end

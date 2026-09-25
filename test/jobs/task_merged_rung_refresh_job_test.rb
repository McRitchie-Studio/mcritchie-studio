# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../support/fake_task_derivation"

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

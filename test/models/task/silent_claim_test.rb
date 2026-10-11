# frozen_string_literal: true

require "test_helper"

# [unit] Task::SilentClaim: a review or build claim whose holder has written no
# activity or task event on the task for 30 minutes. Two reviewer subagents held
# live review leases for six hours on 2026-10-10/11 after ending their turns.
class Task::SilentClaimTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-10-11 12:00:00")

  def submitted_under_review(acquired: 2.hours, slug: "silent-review")
    task = Task.create!(title: "Silent review probe", slug: slug, stage: "submitted")
    TaskReviewClaim.acquire(task_slug: task.slug, session: "sess-r", nonce: "n-1", reviewer: "carl", now: NOW - acquired)
    TaskReviewClaim.find_by!(task_slug: task.slug).update!(claim_expires_at: NOW + 10.minutes) # the renewer keeps it live
    task.task_events.where("occurred_at > ?", NOW - acquired).update_all(occurred_at: NOW - acquired)
    task.reload
  end

  def building_with_claim(slug: "silent-build", blocked: false)
    task = Task.create!(title: "Silent build probe", slug: slug, stage: "building")
    task.update_columns(metadata: { "devops" => { "claimed_session" => "sess-b", "built_by" => "pokemon" } },
                        blocked_at: (NOW if blocked))
    TaskEvent.where(task_slug: task.slug).update_all(occurred_at: NOW - 2.hours)
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building", occurred_at: NOW - 2.hours)
    task.reload
  end

  def narrate(task, at)
    AgentActivity.create!(session_id: "sess-x", category: "Explore", reason_slug: "check ci", opened_at: at,
                          task_slug: task.slug, created_at: at, updated_at: at)
  end

  def silent(task) = Task::SilentClaim.for_task(task, now: NOW)

  test "a live review claim with nothing written for 30 minutes is silent, naming its holder" do
    task = submitted_under_review
    narrate(task, NOW - 45.minutes)

    result = silent(task)

    assert_equal %w[review carl], [result.kind, result.holder]
    assert_equal 45.minutes.to_i, result.seconds.to_i
    assert_equal "silent 30m+", result.label
    assert_match(/review claim held by carl has written nothing on this task for 45m/, result.sentence)
  end

  test "any recent write on the task keeps the claim off the flag" do
    task = submitted_under_review
    narrate(task, NOW - 10.minutes)
    assert_nil silent(task), "a fresh activity"

    task = submitted_under_review(slug: "silent-review-note")
    Activity.create!(task_slug: task.slug, activity_type: "comment", description: "still on it", created_at: NOW - 5.minutes)
    assert_nil silent(task), "a fresh task note"

    task = submitted_under_review(slug: "silent-review-event")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed", kind: "intent",
                      occurred_at: NOW - 5.minutes)
    assert_nil silent(task.reload), "a fresh task event"
  end

  test "a claim taken minutes ago is not silent, whatever came before it" do
    task = submitted_under_review(acquired: 5.minutes)
    narrate(task, NOW - 3.hours)

    assert_nil silent(task)
  end

  test "a lapsed review claim is not a claim" do
    task = submitted_under_review
    TaskReviewClaim.find_by!(task_slug: task.slug).update!(claim_expires_at: NOW - 1.minute)

    assert_nil silent(task.reload)
  end

  test "a build claim goes silent the same way; a blocked one and an unclaimed task never do" do
    assert_equal %w[build pokemon], silent(building_with_claim).then { |r| [r.kind, r.holder] }
    assert_nil silent(building_with_claim(slug: "silent-build-blocked", blocked: true)), "a block waits on someone else"

    unclaimed = Task.create!(title: "Unclaimed build probe", slug: "silent-unclaimed", stage: "building")
    unclaimed.update_columns(metadata: { "devops" => {} })
    assert_nil silent(unclaimed.reload)
  end

  # A broadcaster renders the card from the task it was handed; loading the claim
  # there cached a nil that the next read of that instance trusted.
  test "the single read leaves the caller's task associations unloaded" do
    task = Task.find(submitted_under_review.id)
    narrate(task, NOW - 45.minutes)

    assert_equal "review", silent(task).kind
    refute task.association(:review_claim).loaded?
    refute task.association(:task_events).loaded?
  end

  test "the board's batch read agrees with the single read, in three queries for any number of tasks" do
    quiet = submitted_under_review
    narrate(quiet, NOW - 45.minutes)
    busy = submitted_under_review(slug: "silent-review-busy")
    narrate(busy, NOW - 1.minute)
    build = building_with_claim
    tasks = Task.where(slug: [quiet.slug, busy.slug, build.slug]).includes(:task_events, :review_claim).to_a
    tasks.each { |task| task.task_events.load && task.review_claim }

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    found = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Task::SilentClaim.by_slug(tasks, now: NOW)
    end

    assert_equal [build.slug, quiet.slug].sort, found.keys.sort
    assert_equal 3, queries.size, queries.join("\n")
    assert_equal silent(quiet).seconds, found[quiet.slug].seconds
  end
end

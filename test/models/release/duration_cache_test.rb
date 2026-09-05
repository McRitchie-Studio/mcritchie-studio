require "test_helper"

class Release::DurationCacheTest < ActiveSupport::TestCase
  def create_release_with_task(slug:, shipped_at:, building_seconds:)
    started = shipped_at - 2.hours
    release = Release.create!(slug: slug, branch: "release", state: "shipped")
    release.update_columns( # rubocop:disable Rails/SkipsModelValidations
      created_at: started,
      updated_at: shipped_at,
      assembled_at: shipped_at - 30.minutes,
      confirmed_at: shipped_at - 5.minutes,
      shipped_at: shipped_at
    )

    task = Task.create!(title: "#{slug.tr("-", " ")} task", stage: "shipped", release_slug: release.slug)
    task.task_events.delete_all
    intent_at = started + 5.minutes
    TaskEvent.create!(task_slug: task.slug, kind: "intent", from_stage: "designed", to_stage: "building",
                      occurred_at: intent_at, actor: "builder")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: intent_at + building_seconds, seconds_in_from: building_seconds,
                      actor: "builder", source: "cli", model: "gpt-5",
                      tokens_in: 1000, tokens_out: 200, cost: "0.0500")

    review_at = intent_at + building_seconds + 2.minutes
    TaskEvent.create!(task_slug: task.slug, kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: review_at, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: review_at + 5.minutes, seconds_in_from: 300, actor: "carl",
                      source: "cli", model: "gpt-5", tokens_in: 500, tokens_out: 100, cost: "0.0200")

    assemble_at = review_at + 10.minutes
    TaskEvent.create!(task_slug: task.slug, kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: assemble_at, actor: "steffon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: assemble_at + 7.minutes, seconds_in_from: 420, actor: "steffon",
                      source: "cli", model: "gpt-5", tokens_in: 600, tokens_out: 120, cost: "0.0300")

    ship_at = assemble_at + 12.minutes
    TaskEvent.create!(task_slug: task.slug, kind: "intent", from_stage: "assembled", to_stage: "shipped",
                      occurred_at: ship_at, actor: "avi")
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: ship_at + 11.minutes, seconds_in_from: 660, actor: "avi",
                      source: "cli", model: "gpt-5", tokens_in: 700, tokens_out: 140, cost: "0.0400")

    ReleaseEvent.create!(release: release, step: "deploy_qa", status: "started",
                         occurred_at: shipped_at - 25.minutes, source: "system")
    ReleaseEvent.create!(release: release, step: "deploy_qa", status: "completed",
                         occurred_at: shipped_at - 20.minutes, source: "system")
    release.reload
  end

  test "build measures task spans from intents to conclusions" do
    release = create_release_with_task(
      slug: "rel-duration-cache",
      shipped_at: Time.zone.parse("2026-06-29 12:00:00"),
      building_seconds: 20.minutes
    )

    metrics = Release::DurationCache.build(release)
    task = metrics.fetch("tasks").first

    assert_equal 20.minutes.to_i, task.dig("stages", "building", "seconds")
    assert_equal 5.minutes.to_i, task.dig("stages", "reviewing", "seconds")
    assert_equal 7.minutes.to_i, task.dig("stages", "assembled", "seconds")
    assert_equal 11.minutes.to_i, task.dig("stages", "shipped", "seconds")
    assert_equal "intent", task.dig("stages", "building", "source")
    assert_equal 90.minutes.to_i, metrics.dig("release", "assembly_seconds")
    assert_equal 25.minutes.to_i, metrics.dig("release", "confirmation_seconds")
    assert_equal 5.minutes.to_i, metrics.dig("release", "shipping_seconds")
    assert_equal 2.hours.to_i, metrics.dig("release", "deployment_seconds")
    assert_equal 5.minutes.to_i, metrics.dig("release_steps", "deploy_qa", "seconds")
    assert_equal 1, metrics.dig("stages", "building", "sample_count")
  end

  test "completed-only release events preserve their checkpoint timestamp" do
    release = create_release_with_task(
      slug: "rel-duration-checkpoint",
      shipped_at: Time.zone.parse("2026-06-29 12:00:00"),
      building_seconds: 20.minutes
    )
    occurred_at = Time.zone.parse("2026-06-29 11:45:00")
    ReleaseEvent.create!(release: release, step: "qa_smoke", status: "completed",
                         occurred_at: occurred_at, source: "conductor")

    metrics = Release::DurationCache.build(release)
    step = metrics.dig("release_steps", "qa_smoke")

    assert_equal "completed", step["status"]
    assert_equal occurred_at.iso8601, step["started_at"]
    assert_equal occurred_at.iso8601, step["completed_at"]
    assert_equal 0, step["seconds"]
    assert_equal "completed_only", step["source"]
  end

  test "refresh stores cached metrics on the release record" do
    release = create_release_with_task(
      slug: "rel-duration-refresh",
      shipped_at: Time.zone.parse("2026-06-29 13:00:00"),
      building_seconds: 15.minutes
    )

    Release::DurationCache.refresh!(release)
    release.reload

    assert_equal Release::DurationCache::VERSION, release.duration_cache_version
    assert release.duration_metrics_cached_at.present?
    assert_equal 15.minutes.to_i, release.duration_metrics.dig("tasks", 0, "stages", "building", "seconds")
  end

  test "dashboard averages the last three shipped releases without writing missing caches" do
    now = Time.zone.parse("2026-06-29 14:00:00")
    create_release_with_task(slug: "rel-old", shipped_at: now - 4.hours, building_seconds: 5.minutes)
    create_release_with_task(slug: "rel-one", shipped_at: now - 3.hours, building_seconds: 10.minutes)
    create_release_with_task(slug: "rel-two", shipped_at: now - 2.hours, building_seconds: 20.minutes)
    newest = create_release_with_task(slug: "rel-three", shipped_at: now - 1.hour, building_seconds: 30.minutes)
    newest.update_columns(duration_metrics: {}, duration_metrics_cached_at: nil) # rubocop:disable Rails/SkipsModelValidations

    dashboard = Release::DurationCache.dashboard(limit: 3)

    assert_equal 3, dashboard["sample_count"]
    assert_equal 20.minutes.to_i, dashboard.dig("averages", "stages", "building", "average_seconds")
    assert_empty newest.reload.duration_metrics, "dashboard fallback builds in memory; refresh task owns writes"
  end

  # ---- a block bounce must not be recorded as WHO did the Building stage ---------
  #
  # `building` resolves its start intent-first, then falls back to the last
  # `-> building` TRANSITION before the completion. MEASURED on production 2026-09-05:
  # there are ZERO `intent -> building` rows in the entire ecosystem, so the intent
  # branch never fires and EVERY task's Building stage takes the fallback. The
  # qualification "only the fallback path is exposed" is true as written and total in
  # practice -- the fixture above is the only place an intent-to-building has ever
  # existed. That is why this test builds its trail without one.
  def bounced_task(actor: "shannon", blocker: "carl")
    release = Release.create!(slug: "rel-bounce", branch: "release", state: "shipped")
    task = Task.create!(title: "bounce actor probe", stage: "shipped", release_slug: release.slug)
    task.task_events.delete_all
    anchor = Time.zone.parse("2026-06-29 10:00:00")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: anchor, actor: actor)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: anchor + 20.minutes, actor: actor)
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "building",
                      occurred_at: anchor + 30.minutes, actor: blocker,
                      metadata: { "blocked" => true, "block_kind" => "rework" })
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: anchor + 50.minutes, actor: actor)
    [release.reload, anchor]
  end

  test "the Building stage names the builder, not the blocker who bounced it" do
    release, anchor = bounced_task

    row = Release::DurationCache.build(release).dig("tasks", 0, "stages", "building")

    assert_equal "shannon", row["actor"], "the blocker moved the card; the builder did the stage"
    assert_equal anchor.iso8601, row["started_at"], "the build claim opens the stage"
    assert_equal 50.minutes.to_i, row["seconds"]
  end

  test "an ordinary transition-fallback start is still the Building stage's start" do
    # The over-broad direction: rejecting every `-> building` transition would leave the
    # stage with no start at all on the majority of real tasks, which have no intent row.
    release = Release.create!(slug: "rel-no-intent", branch: "release", state: "shipped")
    task = Task.create!(title: "no intent probe", stage: "shipped", release_slug: release.slug)
    task.task_events.delete_all
    anchor = Time.zone.parse("2026-06-29 10:00:00")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: anchor, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: anchor + 12.minutes, actor: "shannon")

    row = Release::DurationCache.build(release.reload).dig("tasks", 0, "stages", "building")

    assert_equal "transition_fallback", row["source"]
    assert_equal "shannon", row["actor"]
    assert_equal 12.minutes.to_i, row["seconds"], "the ordinary fallback path is untouched"
  end

  test "the intent path still outranks the transition fallback" do
    release = create_release_with_task(slug: "rel-intent-wins", shipped_at: Time.zone.parse("2026-06-29 12:00:00"),
                                       building_seconds: 20.minutes)

    row = Release::DurationCache.build(release).dig("tasks", 0, "stages", "building")

    assert_equal "intent", row["source"], "an intent, where one exists, still wins"
    assert_equal "builder", row["actor"]
  end
end

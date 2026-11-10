require "test_helper"

# [unit] Ci::CauseCleanup, the one-time board heal behind `bin/rails ci:causes:cleanup`
# (task ci-cause-board-cleanup): race twins of one cause merge into one card, and past
# native crashes filed under another key move onto native-abort. Dry run by default;
# a second applied run changes nothing.
class Ci::CauseCleanupTest < ActiveSupport::TestCase
  TURF = "McRitchie-Studio/turf-monster"

  # The real occurrence from turf run 42745469708 attempt 1, as the board holds it.
  CRASH = {
    "id" => "42745469708/1/129596390504", "job" => "playwright (1)", "repo" => TURF,
    "sha" => "1d61bc9eaecb0ee0d0f6f41cb6cfa480754996d6", "seen_at" => "2026-11-10T03:18:52Z",
    "evidence" => ["[WebServer]  (called from <main> at /__w/turf-monster/turf-monster/config/application.rb:7)",
                   "[WebServer] malloc_consolidate(): unaligned fastbin chunk detected",
                   "[WebServer] Aborted (core dumped)",
                   "Error: Process from config.webServer was not able to start. Exit code: 134"]
  }.freeze
  CENSUS = { "id" => "42745469708/1/129596400001", "job" => "e2e_executed_set", "repo" => TURF,
             "seen_at" => "2026-11-10T03:18:53Z", "evidence" => ["the lane EXECUTED 403 spec(s)"] }.freeze
  BOOT = { "id" => "42700000000/1/1", "job" => "playwright (2)", "repo" => TURF, "seen_at" => "2026-11-08T01:00:00Z",
           "evidence" => ["Error: Timed out waiting 120000ms from config.webServer."] }.freeze

  def card(slug, key, occurrences, stage: "designed", klass: "harness")
    Task.create!(slug: slug, title: "Find #{klass} cause #{key}", stage: stage,
                 metadata: { "devops" => { "kind" => "bug", "repositories" => ["turf-monster"] },
                             "ci_cause" => { "class" => klass, "key" => key, "repo" => TURF, "repos" => [TURF],
                                             "count" => occurrences.size, "occurrences" => occurrences } })
  end

  def ids(slug) = Task.find_by!(slug: slug).metadata.dig("ci_cause", "occurrences").map { |o| o["id"] }

  test "[unit] a dry run plans the merge and the re-key and writes nothing" do
    card("ci-cause-turf-monster-web-server-boot", "web-server-boot", [CRASH], stage: "archived")
    card("ci-cause-turf-monster-web-server-boot-2", "web-server-boot", [CRASH], stage: "archived")
    before = Task.order(:id).pluck(:slug, :stage, :metadata)

    actions = Ci::CauseCleanup.call

    assert_equal [%w[merge ci-cause-turf-monster-web-server-boot-2 ci-cause-turf-monster-web-server-boot],
                  %w[rekey ci-cause-turf-monster-web-server-boot ci-cause-turf-monster-native-abort]],
                 actions.map { |a| [a.kind, a.from, a.to] }
    assert_equal before, Task.order(:id).pluck(:slug, :stage, :metadata)
  end

  test "[unit] the rake merges a base and -2 card of one cause into one" do
    card("ci-cause-turf-monster-web-server-boot", "web-server-boot", [BOOT])
    twin = card("ci-cause-turf-monster-web-server-boot-2", "web-server-boot",
                [BOOT, BOOT.merge("id" => "42700000001/1/1", "seen_at" => "2026-11-09T01:00:00Z")])

    Ci::CauseCleanup.call(apply: true)

    assert_equal ["42700000000/1/1", "42700000001/1/1"], ids("ci-cause-turf-monster-web-server-boot")
    assert_equal 2, Task.find_by!(slug: "ci-cause-turf-monster-web-server-boot").metadata.dig("ci_cause", "count")
    twin.reload
    assert_equal "archived", twin.stage
    assert_empty twin.metadata.dig("ci_cause", "occurrences")
    assert_equal "ci-cause-turf-monster-web-server-boot", twin.metadata.dig("ci_cause", "merged_into")
  end

  test "[unit] a -2 that shares no occurrence is a real reopening and stays" do
    card("ci-cause-turf-monster-web-server-boot", "web-server-boot", [BOOT], stage: "shipped")
    card("ci-cause-turf-monster-web-server-boot-2", "web-server-boot", [BOOT.merge("id" => "42800000000/1/1")])

    assert_empty Ci::CauseCleanup.call(apply: true)
  end

  test "[unit] turf run 42745469708: the twins merge, the crash and its census move onto one native-abort card" do
    card("ci-cause-turf-monster-web-server-boot", "web-server-boot", [CRASH], stage: "archived")
    card("ci-cause-turf-monster-web-server-boot-2", "web-server-boot", [CRASH], stage: "archived")
    card("ci-cause-turf-monster-job-e2e-executed-set", "job:e2e_executed_set", [CENSUS], stage: "archived")
    card("ci-cause-turf-monster-web-server-boot-3", "web-server-boot", [BOOT])

    Ci::CauseCleanup.call(apply: true)

    native = Task.find_by!(slug: "ci-cause-turf-monster-native-abort")
    assert_equal "archived", native.stage, "a crash already closed out lands on a closed card, not new work"
    assert_equal [CRASH["id"], CENSUS["id"]], ids(native.slug)
    assert_equal "playwright (1)", native.metadata.dig("ci_cause", "occurrences").last["follows"]
    assert_equal %w[harness native-abort 2], native.metadata["ci_cause"].values_at("class", "key", "count").map(&:to_s)
    assert_empty ids("ci-cause-turf-monster-web-server-boot")
    assert_equal ["ci-cause-turf-monster-native-abort"],
                 Task.find_by!(slug: "ci-cause-turf-monster-web-server-boot").metadata.dig("ci_cause", "moved_to")
    assert_equal [BOOT["id"]], ids("ci-cause-turf-monster-web-server-boot-3"), "a real boot timeout stays put"
  end

  test "[unit] a crash on an open card moves onto an open native-abort card and the emptied card is archived" do
    open_card = card("ci-cause-turf-monster-web-server-boot", "web-server-boot", [CRASH])

    Ci::CauseCleanup.call(apply: true)

    assert_equal "designed", Task.find_by!(slug: "ci-cause-turf-monster-native-abort").stage
    assert_equal "archived", open_card.reload.stage
  end

  test "[unit] the cleanup is idempotent: a second applied run finds nothing" do
    card("ci-cause-turf-monster-web-server-boot", "web-server-boot", [CRASH], stage: "archived")
    card("ci-cause-turf-monster-web-server-boot-2", "web-server-boot", [CRASH], stage: "archived")
    Ci::CauseCleanup.call(apply: true)
    after = Task.order(:id).pluck(:slug, :stage, :metadata)

    assert_empty Ci::CauseCleanup.call(apply: true)
    assert_equal after, Task.order(:id).pluck(:slug, :stage, :metadata)
  end
end

# [unit] The operator's entry point: `bin/rails ci:causes:cleanup` plans and writes
# nothing unless APPLY=1.
class Ci::CauseCleanupRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ci:causes:cleanup")
    Rake::Task["ci:causes:cleanup"].reenable
  end

  test "[unit] the rake is a dry run unless APPLY=1" do
    slug = "ci-cause-turf-monster-web-server-boot"
    Task.create!(slug: slug, title: "Find harness cause web-server-boot", stage: "designed",
                 metadata: { "ci_cause" => { "class" => "harness", "key" => "web-server-boot",
                                             "repo" => Ci::CauseCleanupTest::TURF, "count" => 1,
                                             "occurrences" => [Ci::CauseCleanupTest::CRASH] } })

    saved = ENV.delete("APPLY")
    out, = capture_io { Rake::Task["ci:causes:cleanup"].invoke }
    ENV["APPLY"] = saved if saved

    assert_includes out, "would apply rekey: #{slug} -> ci-cause-turf-monster-native-abort"
    assert_includes out, "(DRY RUN; APPLY=1 to write)"
    assert_not Task.exists?(slug: "ci-cause-turf-monster-native-abort")
  end
end

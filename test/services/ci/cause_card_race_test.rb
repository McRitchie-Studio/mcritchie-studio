require "test_helper"

# [unit] Ci::CauseCard#file!: two CiCauseCardJob runs for ONE red (the ingest and the
# sweep, or a re-delivered webhook) make ONE card. Turf run 42745469708 made two,
# web-server-boot and -2, 123ms apart, holding the identical occurrence: each run
# locked the open card, but with no card yet that lock covered zero rows, so both
# saw none and the second took the next free slug (task ci-cause-card-dedupe-census).
#
# Two real Postgres connections, so transactional tests are off: one shared
# connection cannot tell a lock from luck. The interleave is pinned, not hoped for
# (file_together).
class Ci::CauseCardRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  REPO = "McRitchie-Studio/turf-monster"
  CAUSE = { klass: "harness", key: "race-test-boot", reason: "the server died", evidence: ["Exit code: 134"] }.freeze
  BASE = "ci-cause-turf-monster-race-test-boot"

  setup { sweep! }
  teardown { sweep! }

  # Everything this file committed. Task.create! writes a genesis TaskEvent (and may
  # write an Activity) that delete_all would orphan, so the children go first.
  def sweep!
    slugs = cards.pluck(:slug)
    Activity.where(task_slug: slugs).delete_all
    TaskEvent.where(task_slug: slugs).delete_all
    cards.delete_all
  end

  # The race exactly: the LATE filer looks for an open card and finds none, then the
  # EARLY filer creates the card and commits, then the late filer picks its slug. The
  # late filer is held after its look until the early one is done (at most 2s: with
  # the fix the late filer holds the cause's lock, so the early one waits on it and
  # the hold runs out once).
  def file_together(late_id, early_id)
    looked = Concurrent::Event.new
    early_done = Concurrent::Event.new
    late = Ci::CauseCard.new(REPO, CAUSE, { "id" => late_id, "repo" => REPO, "sha" => "deadbeef" })
    late.define_singleton_method(:open_card) do |base|
      super(base).tap do
        looked.set
        early_done.wait(2)
      end
    end
    early = Ci::CauseCard.new(REPO, CAUSE, { "id" => early_id, "repo" => REPO, "sha" => "deadbeef" })

    threads = [Thread.new { on_own_connection { late.file! } },
               Thread.new do
                 looked.wait(10) || raise("the late filer never looked: the race was not set up")
                 on_own_connection { early.file! }
               ensure
                 early_done.set
               end]
    threads.each { |t| t.join(20) || flunk("a filer never returned") }
    threads.each(&:value)
  ensure
    threads&.each { |t| t.kill if t.alive? }
  end

  def on_own_connection(&) = ActiveRecord::Base.connection_pool.with_connection(&)

  def cards = Task.where(slug: BASE).or(Task.where("slug LIKE ?", "#{BASE}-%")).order(:id)

  test "[unit] two concurrent files of one occurrence make one card with it once" do
    file_together("42745469708/1/129596390504", "42745469708/1/129596390504")

    assert_equal [BASE], cards.pluck(:slug), "one red must file one card, never a -2"
    assert_equal ["42745469708/1/129596390504"], cards.sole.metadata.dig("ci_cause", "occurrences").map { |o| o["id"] }
  end

  test "[unit] two concurrent files of two occurrences of one cause fold onto one card" do
    file_together("500/1/1", "600/1/1")

    assert_equal [BASE], cards.pluck(:slug)
    assert_equal %w[500/1/1 600/1/1], cards.sole.metadata.dig("ci_cause", "occurrences").map { |o| o["id"] }.sort
    assert_equal 2, cards.sole.metadata.dig("ci_cause", "count")
  end
end

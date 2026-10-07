require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require_relative "../../support/tiktok_draft_fakes"

# [unit] One press, one draft, with the database arbitrating: two real Postgres
# connections request a draft of one clip at the same instant.
#
# A single connection cannot tell a lock from luck, so transactional fixtures
# are off here: Rails pins one shared connection for a transactional test, and
# two threads would take turns on it. Every row is really committed, and
# teardown removes them.
#
# The interleave is pinned, not hoped for. The pending check is the first thing
# a request does and the ESPN read comes after it, so the fake ESPN holds each
# request at its first read until BOTH have arrived: both have then passed the
# check with no attempt on file, which is the double press exactly.
class Tiktok::DraftClipRaceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  setup do
    sweep!
    video = TiledVideo.seed!
    person = Person.create!(athlete: true, first_name: "Test", last_name: "Tiktok Race")
    look = person.appearances.live.create!(descriptor: "Home", team_slug: "buffalo-bills")
    video.video_performers.find_by!(ordinal: 1).update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
    @clip = AltVideo.build_from!(video.reload).clips.first
    TiledVideo.version!(@clip, number: 1)
    Tiktok::DraftClip.uploader = TiktokDraftFakes::Uploader.new
  end

  teardown do
    Tiktok::DraftClip.uploader = nil
    sweep!
  end

  # Everything this file committed. The un-fixtured tables are emptied the way
  # the leak guard empties them; the one row in a fixtured table (the person)
  # goes by name, after the rows that point at it.
  def sweep!
    ActiveRecord::Base.connection_pool.with_connection { |connection| TestDatabaseLeakGuard.sweep!(connection) }
    Person.where(last_name: "Tiktok Race").delete_all
  end

  def service(fetch: TiktokDraftFakes.espn)
    Tiktok::DraftClip.new(reader: TiktokDraftFakes::Reader.new, fetch:, sleeper: ->(_) { })
  end

  # A thread on its OWN connection. Its value is the draft, or the refusal.
  def press
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        yield
      rescue Tiktok::DraftClip::Refused => e
        e
      end
    end
  end

  def settle(threads)
    threads.map { |t| t.join(20) ? t.value : flunk("a press never returned") }
  ensure
    threads.each { |t| t.kill if t.alive? }
  end

  # ESPN that holds a request at its first read until `presses` have arrived.
  def espn_holding_until_all_arrive(presses)
    arrived = Concurrent::CountDownLatch.new(presses)
    espn = TiktokDraftFakes.espn(names: ["Buffalo Bills"])
    lambda do |url|
      if url.end_with?("/teams")
        arrived.count_down
        arrived.wait(10) or raise "only one press reached ESPN: the double press was not set up"
      end
      espn.call(url)
    end
  end

  test "two presses that both pass the pending check make one draft; the other is refused" do
    fetch = espn_holding_until_all_arrive(2)
    results = settle(Array.new(2) { press { service(fetch:).request!(AltVideoClip.find(@clip.id), by: "alex@test.com") } })

    drafts, refusals = results.partition { |r| r.is_a?(TiktokDraft) }
    assert_equal 1, TiktokDraft.where(clip_slug: @clip.slug).count, "two presses must record one attempt"
    assert_equal [1, 1], [drafts.size, refusals.size]
    assert_match(/a draft of #{@clip.slug} is already queued \(attempt #{drafts.sole.id}\)/, refusals.sole.message)
    assert_enqueued_jobs 1, only: TiktokDraftJob
  end

  test "concurrent record! on one clip yields one pending attempt, round after round" do
    previews = Array.new(2) { service.check!(AltVideoClip.find(@clip.id)) }

    10.times do |round|
      gate = Queue.new
      threads = previews.map do |pv|
        press do
          gate.pop
          service.record!(pv)
        end
      end
      2.times { gate << :go }
      results = settle(threads)

      pending = TiktokDraft.pending.where(clip_slug: @clip.slug)
      assert_equal 1, pending.count, "round #{round}: exactly one record! may win"
      assert_equal 1, results.count { |r| r.is_a?(Tiktok::DraftClip::Refused) }, "round #{round}: the loser is told"
      pending.update_all(state: "failed")
    end
  end
end

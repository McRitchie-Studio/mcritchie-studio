require "test_helper"
require "minitest/mock"

# RELEASE NOTES REMEMBER WHETHER THEY WERE DELIVERED (close-review-leftovers-bundle, fix 2).
#
# THE DEFECT: `bin/release notes <slug> --post` re-posted to Discord with no idea
# whether the ship had already delivered — the release_notes completed event was
# written whether or not Discord took the message. So a repost meant for a FAILED
# delivery could double-post a good one. The completed event now carries
# metadata.delivered + metadata.messages, and a repost over a delivered release
# refuses without force.
class Release::NotesDeliveryTest < ActiveSupport::TestCase
  def shipped_release
    task = Task.create!(title: "notes delivery demo task", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "backend", "repositories" => ["mcritchie-studio"] } })
    rel = Release::Conductor.prepare!(task_slugs: [task.slug])
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", by: "alex", production_url: "https://example.test")
    rel
  end

  def completed_notes_event(rel)
    rel.release_events.for_step("release_notes").completed.chronological.last
  end

  def delivering(&block)
    calls = []
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content: nil, embeds: nil) { calls << content }) { block.call(calls) }
    calls
  end

  test "[unit] a delivered post records delivered: true and the message count on the completed event" do
    rel = shipped_release
    delivering { Release::Conductor.post_release_notes(release: rel) }

    meta = completed_notes_event(rel).metadata
    assert_equal true, meta["delivered"]
    assert_equal 1, meta["messages"]
    assert rel.release_notes_delivered?
  end

  # A ship or finalize RE-RUN calls post_release_notes again on the same release
  # (2026-10-27: the notes went to Discord twice). The second call posts nothing,
  # leaves the delivery record alone, and says it skipped.
  test "[unit] a re-run posts no second Discord message" do
    rel = shipped_release
    first = nil
    calls = delivering { first = Release::Conductor.post_release_notes(release: rel) }
    assert_equal 1, calls.size
    assert first[:delivered]
    assert_not first[:already_delivered]
    delivered_at = completed_notes_event(rel).metadata["delivered_at"]

    second = nil
    calls = delivering { second = Release::Conductor.post_release_notes(release: rel.reload) }
    assert_empty calls, "the re-run posts no second Discord message"
    assert second[:already_delivered], "the result says the notes were already out"
    assert_not second[:delivered], "nothing was delivered by THIS call"
    assert_nil second[:error]
    assert_equal delivered_at, completed_notes_event(rel).metadata["delivered_at"], "the first delivery's record stands"
    assert_equal 1, rel.release_events.for_step("release_notes").completed.count
  end

  test "[unit] a re-run after a FAILED delivery does post: only a delivery skips" do
    rel = shipped_release
    ReleaseNotes::DiscordClient.stub(:deliver, ->(**) { raise ReleaseNotes::DiscordClient::MissingWebhook, "no webhook" }) do
      Release::Conductor.post_release_notes(release: rel)
    end

    result = nil
    calls = delivering { result = Release::Conductor.post_release_notes(release: rel.reload) }
    assert_equal 1, calls.size
    assert result[:delivered]
    assert_not result[:already_delivered]
  end

  test "[unit] a failed delivery records delivered: false, so a repost is not refused" do
    rel = shipped_release
    ReleaseNotes::DiscordClient.stub(:deliver, ->(**) { raise ReleaseNotes::DiscordClient::MissingWebhook, "no webhook" }) do
      Release::Conductor.post_release_notes(release: rel)
    end

    assert_equal false, completed_notes_event(rel).metadata["delivered"]
    assert_not rel.release_notes_delivered?

    calls = delivering { |_| assert Release::Conductor.repost_release_notes(release: rel, dry_run: false)[:delivered] }
    assert_equal 1, calls.size, "the repost a failed delivery needs goes through"
    assert rel.reload.release_notes_delivered?, "the repost's delivery is recorded on the event"
    assert_equal 1, rel.release_events.for_step("release_notes").completed.count, "recorded ON the event, not as a new one"
  end

  test "[integration] a repost over delivered notes is refused without force and posts nothing" do
    rel = shipped_release
    delivering { Release::Conductor.post_release_notes(release: rel) }

    result = nil
    calls = delivering { result = Release::Conductor.repost_release_notes(release: rel, dry_run: false) }
    assert_empty calls, "already-delivered notes are not posted twice"
    assert result[:already_delivered]
    assert result[:refused]
    assert_not result[:delivered]

    calls = delivering { result = Release::Conductor.repost_release_notes(release: rel, dry_run: false, force: true) }
    assert_equal 1, calls.size, "force posts again"
    assert result[:delivered]
    assert_not result[:refused]
  end

  test "[unit] a dry-run repost reports the prior delivery without refusing" do
    rel = shipped_release
    delivering { Release::Conductor.post_release_notes(release: rel) }

    result = Release::Conductor.repost_release_notes(release: rel)
    assert result[:already_delivered], "the preview says the notes already went out"
    assert_not result[:refused]
  end

  test "[unit] a release whose event predates the flag reads as not delivered" do
    rel = shipped_release
    Release::Conductor.post_release_notes(release: rel, dry_run: true)
    completed_notes_event(rel).update!(metadata: {})

    assert_not rel.release_notes_delivered?, "unknown is not delivered — the repost stays possible"
  end
end

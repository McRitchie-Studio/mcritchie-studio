require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require_relative "../../support/tiktok_draft_fakes"

# [integration] Tiktok::DraftClip — a clip's primary version into the
# operator's TikTok drafts: the attempt is recorded with the code's caption and
# the version it sends, the upload runs once, TikTok's status settles it, and
# every refusal and failure is visible on the row. TikTok, R2 and ESPN are fakes.
class Tiktok::DraftClipTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @video = TiledVideo.seed!
    person = Person.create!(athlete: true, first_name: "Test", last_name: "Tiktok Gamma")
    look = person.appearances.live.create!(descriptor: "Home", team_slug: "buffalo-bills")
    Team.find_by!(slug: "buffalo-bills").update!(hashtag: "#BillsMafia")
    @video.video_performers.find_by!(ordinal: 1).update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
    @alt = AltVideo.build_from!(@video.reload)
    @clip = @alt.clips.first
    TiledVideo.version!(@clip, number: 1, at: 2.minutes.ago)
    @v2 = TiledVideo.version!(@clip, number: 2, at: 1.minute.ago)
    @uploader = TiktokDraftFakes::Uploader.new
    @reader = TiktokDraftFakes::Reader.new
  end

  def service(uploader: @uploader, **opts)
    Tiktok::DraftClip.new(uploader:, reader: @reader, fetch: TiktokDraftFakes.espn, sleeper: ->(_) {}, **opts)
  end

  def with_available
    Tiktok::DraftClip.uploader = @uploader
    yield
  ensure
    Tiktok::DraftClip.uploader = nil
  end

  test "request records the primary version and the code's caption, and queues the upload" do
    draft = with_available { service.request!(@clip.reload, by: "alex@test.com") }

    assert_equal ["queued", 2, @v2.object_key, "alex@test.com"], [draft.state, draft.version_number, draft.version_object_key, draft.requested_by]
    assert_equal "Bills 3-2 #nfl #nfltiktok #footballtiktok #billsmafia #bills #fyp", draft.caption
    assert_equal ["Test Tiktok Gamma", "the clip's target", "buffalo-bills", "look"],
                 draft.facts.values_at("athlete", "athlete_rule", "team_slug", "team_from")
    assert_enqueued_with(job: TiktokDraftJob, args: [draft.id])
  end

  test "a clip with no primary version is refused and nothing is recorded" do
    bare = @alt.clips.second
    error = with_available { assert_raises(Tiktok::DraftClip::Refused) { service.request!(bare) } }

    assert_match(/Clip 2 has no generated version yet/, error.message)
    assert_equal 0, TiktokDraft.count
    assert_no_enqueued_jobs
  end

  test "a server without TikTok keys refuses before reading anything" do
    error = assert_raises(Tiktok::DraftClip::Refused) { service.request!(@clip) }

    assert_match(/TikTok keys are not set on this server/, error.message)
    assert_equal 0, TiktokDraft.count
  end

  test "an attempt in flight blocks a second; a failed or stuck one does not" do
    first = with_available { service.request!(@clip.reload) }
    error = with_available { assert_raises(Tiktok::DraftClip::Refused) { service.request!(@clip.reload) } }
    assert_match(/already queued \(attempt #{first.id}\)/, error.message)

    first.update!(state: "failed")
    assert with_available { service.request!(@clip.reload) }

    TiktokDraft.update_all(state: "uploading", created_at: 20.minutes.ago)
    assert with_available { service.request!(@clip.reload) }, "a draft pending past STUCK_AFTER is dead"
  end

  test "run uploads every byte once, records the publish id and settles on TikTok's word" do
    @uploader = TiktokDraftFakes::Uploader.new(statuses: %w[PROCESSING_UPLOAD SEND_TO_USER_INBOX])
    draft = with_available { service.request!(@clip.reload) }
    service.run(draft)
    draft.reload

    assert_equal ["delivered", "SEND_TO_USER_INBOX", "v_inbox_file~synthetic.1", 1, 3_000],
                 [draft.state, draft.tiktok_status, draft.publish_id, draft.chunk_count, draft.byte_size]
    assert_equal [{ size: 3_000, bytes: 3_000 }], @uploader.uploads
    assert_equal [[@v2.object_key, 0, 3_000]], @reader.reads
    assert_equal 2, @uploader.status_reads
    assert draft.finished_at
  end

  test "only the run that claims the queued row uploads" do
    draft = with_available { service.request!(@clip.reload) }
    service.run(draft)
    service.run(draft) # a re-delivered job

    assert_equal 1, @uploader.uploads.size
  end

  test "a TikTok refusal fails the attempt with TikTok's words and keeps the publish id" do
    failing = TiktokDraftFakes::Uploader.new(fail_with: "TikTok refused chunk 1 of 1 (HTTP 400): invalid_params")
    draft = with_available { service.request!(@clip.reload) }
    service(uploader: failing).run(draft)
    draft.reload

    assert_equal ["failed", "v_inbox_file~synthetic.1"], [draft.state, draft.publish_id]
    assert_match(/chunk 1 of 1/, draft.error)
  end

  test "TikTok's FAILED status fails the attempt with its reason" do
    draft = with_available { service.request!(@clip.reload) }
    service(uploader: TiktokDraftFakes::Uploader.new(statuses: ["FAILED"])).run(draft)

    assert_equal ["failed", "FAILED", "file_format_check_failed"], draft.reload.values_at(:state, :tiktok_status, :fail_reason)
  end

  test "a draft still processing when the poll runs out stays processing; refresh settles it later" do
    clock = Time.current
    slow = TiktokDraftFakes::Uploader.new(statuses: ["PROCESSING_UPLOAD"])
    ticking = service(uploader: slow, now: -> { clock += 30 })
    draft = with_available { service.request!(@clip.reload) }
    ticking.run(draft)
    assert_equal ["processing", "PROCESSING_UPLOAD"], draft.reload.values_at(:state, :tiktok_status)

    service(uploader: TiktokDraftFakes::Uploader.new).refresh(draft)
    assert_equal "delivered", draft.reload.state
  end

  test "preview writes nothing and calls no TikTok" do
    pv = service.preview(@clip.reload)

    assert_equal [2, "Test Tiktok Gamma", "Buffalo Bills"], [pv.version.number, pv.choice.entry.person_name, pv.choice.team.name]
    assert_equal 0, TiktokDraft.count
    assert_empty @uploader.uploads
  end
end

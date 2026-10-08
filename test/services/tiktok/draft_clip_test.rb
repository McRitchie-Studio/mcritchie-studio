require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require_relative "../../support/tiktok_draft_fakes"

# [integration] Tiktok::DraftClip — a clip's primary version into the
# operator's TikTok inbox: the attempt is recorded with the code's caption and
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
    Tiktok::DraftClip.new(uploader:, reader: @reader, fetch: TiktokDraftFakes.espn, sleeper: ->(_) { }, **opts)
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

  # ── Hardening (piece 22) ───────────────────────────────────────────────────

  # ESPN that answers, then lets a second press land before the first records:
  # the double press as one connection can express it.
  def espn_with_a_press_landing_mid_read
    espn = TiktokDraftFakes.espn
    landed = false
    lambda do |url|
      unless landed
        landed = true
        TiktokDraft.create!(clip: @clip, version_number: 2, version_object_key: @v2.object_key, caption: "the other press", state: "queued")
      end
      espn.call(url)
    end
  end

  test "a press that lands while this one reads ESPN is seen again under the lock: one draft" do
    racing = Tiktok::DraftClip.new(uploader: @uploader, reader: @reader, fetch: espn_with_a_press_landing_mid_read, sleeper: ->(_) { })
    error = with_available { assert_raises(Tiktok::DraftClip::Refused) { racing.request!(@clip.reload) } }

    assert_match(/already queued \(attempt #{TiktokDraft.sole.id}\)/, error.message)
    assert_equal ["the other press"], TiktokDraft.pluck(:caption)
    assert_no_enqueued_jobs
  end

  # A clock that runs 30 s a read, so a poll that never settles runs out.
  def ticking
    clock = Time.current
    -> { clock += 30 }
  end

  # TikTok that took every byte, then cannot be asked how it went.
  class StatusBreaks < TiktokDraftFakes::Uploader
    def initialize(error, times: Float::INFINITY, **opts)
      super(**opts)
      @error = error
      @times = times
    end

    def status(publish_id)
      if @times.positive?
        @times -= 1
        @status_reads += 1
        raise @error
      end
      super
    end
  end

  [OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof"), EOFError.new("end of file reached"),
   Net::ReadTimeout.new, NoMethodError.new("undefined method `[]' for nil")].each do |boom|
    test "a #{boom.class} from the status poll after the upload finished never fails the attempt" do
      broken = StatusBreaks.new(boom)
      draft = with_available { service.request!(@clip.reload) }
      service(uploader: broken, now: ticking).run(draft)
      draft.reload

      assert_equal 1, broken.uploads.size, "the bytes are with TikTok"
      assert_equal "unknown", draft.state, "a finished upload is never marked failed by a poll error"
      refute draft.failed?
      assert_equal ["v_inbox_file~synthetic.1", "Uploaded, status unknown"], [draft.publish_id, draft.state_label]
      assert draft.uploaded_at
      assert_nil draft.finished_at
      assert_match(/check your TikTok inbox on the phone/i, draft.error)
      assert_includes draft.error, boom.class.name
    end
  end

  test "an attempt uploaded with its status unknown blocks a second draft, and is never sent again" do
    broken = StatusBreaks.new(EOFError.new("end of file reached"))
    draft = with_available { service.request!(@clip.reload) }
    service(uploader: broken, now: ticking).run(draft)

    error = with_available { assert_raises(Tiktok::DraftClip::Refused) { service.request!(@clip.reload) } }
    assert_match(/already uploaded, status unknown \(attempt #{draft.id}\)/, error.message)

    service(uploader: broken).run(draft.reload) # a re-delivered job
    assert_equal 1, broken.uploads.size
    assert_equal 1, TiktokDraft.count
  end

  test "a poll that breaks once keeps reading inside its window and settles on TikTok's word" do
    flaky = StatusBreaks.new(OpenSSL::SSL::SSLError.new("SSL_read"), times: 1)
    draft = with_available { service.request!(@clip.reload) }
    service(uploader: flaky).run(draft)

    assert_equal ["delivered", "SEND_TO_USER_INBOX", nil], draft.reload.values_at(:state, :tiktok_status, :error)
    assert_equal 2, flaky.status_reads
  end

  test "Check TikTok re-polls an attempt whose status is unknown and settles it" do
    draft = with_available { service.request!(@clip.reload) }
    service(uploader: StatusBreaks.new(EOFError.new("end of file reached")), now: ticking).run(draft)
    assert_equal "unknown", draft.reload.state

    service(uploader: TiktokDraftFakes::Uploader.new).refresh(draft)
    assert_equal ["delivered", nil], draft.reload.values_at(:state, :error)
    assert draft.finished_at
  end

  test "a record write that breaks after the upload finished leaves the attempt unknown, never failed" do
    draft = with_available { service.request!(@clip.reload) }
    writes = 0
    # run writes the publish id when TikTok opens the upload (1), then the
    # finished upload (2): that second write is the one that breaks.
    flaky_write = lambda do |attrs|
      writes += 1
      raise ActiveRecord::ConnectionTimeoutError, "could not obtain a connection" if writes == 2

      draft.assign_attributes(attrs)
      draft.save!
    end

    draft.stub(:update!, flaky_write) { assert_raises(ActiveRecord::ConnectionTimeoutError) { service.run(draft) } }

    assert_equal 1, @uploader.uploads.size, "the bytes are with TikTok"
    assert_equal ["unknown", "v_inbox_file~synthetic.1"], draft.reload.values_at(:state, :publish_id)
    assert_match(/check your TikTok inbox on the phone/i, draft.error)
  end

  test "an upload that breaks before every byte is sent still fails, so a retry is right" do
    draft = with_available { service.request!(@clip.reload) }
    reader = TiktokDraftFakes::Reader.new
    reader.define_singleton_method(:read) { |*| raise EOFError, "end of file reached" }

    assert_raises(EOFError) { Tiktok::DraftClip.new(uploader: @uploader, reader:, fetch: TiktokDraftFakes.espn, sleeper: ->(_) { }).run(draft) }
    assert_equal "failed", draft.reload.state
    assert_empty @uploader.uploads
  end

  [OpenSSL::SSL::SSLError.new("SSL_connect returned=1"), EOFError.new("end of file reached"), Net::OpenTimeout.new,
   Net::ReadTimeout.new, Errno::ECONNRESET.new, SocketError.new("getaddrinfo")].each do |boom|
    test "ESPN down with #{boom.class} is a refusal: nothing recorded, nothing queued" do
      down = Tiktok::DraftClip.new(uploader: @uploader, reader: @reader, fetch: ->(_url) { raise boom }, sleeper: ->(_) { })
      error = with_available { assert_raises(Tiktok::DraftClip::Refused) { down.request!(@clip.reload) } }

      assert_match(/could not read ESPN/, error.message)
      assert_includes error.message, boom.class.name
      assert_equal 0, TiktokDraft.count
      assert_no_enqueued_jobs
    end
  end
end

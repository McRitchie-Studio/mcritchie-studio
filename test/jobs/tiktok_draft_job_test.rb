require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require_relative "../support/tiktok_draft_fakes"

# [integration] TiktokDraftJob is never retried. ApplicationJob retries any
# StandardError three times, and a retried upload is a second draft on the
# operator's phone: this pins the job's `discard_on StandardError`, with the
# upload and the status poll each raising, so removing it is a red test.
class TiktokDraftJobTest < ActiveJob::TestCase
  # TikTok that counts what it was asked to do, then breaks where told.
  class Breaking < TiktokDraftFakes::Uploader
    attr_reader :calls

    def initialize(at:)
      super()
      @at = at
      @calls = 0
    end

    def call(size:, read:, &block)
      @calls += 1
      raise "TikTok client broke mid-upload" if @at == :upload

      super
    end

    def status(_publish_id)
      @status_reads += 1
      raise "TikTok client broke reading the status"
    end
  end

  setup do
    video = TiledVideo.seed!
    clip = AltVideo.build_from!(video).clips.first
    @draft = TiktokDraft.create!(clip:, version_number: 1, version_object_key: "synthetic/key.mp4", caption: "Bills 3-2", state: "queued")
    Tiktok::DraftClip.reader = TiktokDraftFakes::Reader.new
    Tiktok::DraftClip.sleeper = ->(seconds) { travel(seconds.seconds) } # the poll window runs out without a real wait
  end

  teardown { Tiktok::DraftClip.uploader = Tiktok::DraftClip.reader = Tiktok::DraftClip.sleeper = nil }

  test "an upload that raises is not re-enqueued and not re-uploaded" do
    Tiktok::DraftClip.uploader = uploader = Breaking.new(at: :upload)

    perform_enqueued_jobs { TiktokDraftJob.perform_later(@draft.id) }

    assert_equal 1, uploader.calls, "one upload, never a second"
    assert_no_enqueued_jobs
    assert_equal 1, performed_jobs.size
    assert_equal "failed", @draft.reload.state
  end

  test "a status poll that raises after the upload is not re-enqueued and not re-uploaded" do
    Tiktok::DraftClip.uploader = uploader = Breaking.new(at: :status)

    perform_enqueued_jobs { TiktokDraftJob.perform_later(@draft.id) }

    assert_equal [1, 1], [uploader.calls, uploader.uploads.size], "one upload, never a second"
    assert_no_enqueued_jobs
    assert_equal 1, performed_jobs.size
    refute_equal "failed", @draft.reload.state
  end
end

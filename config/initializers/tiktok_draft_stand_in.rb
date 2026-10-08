# frozen_string_literal: true

# THE STAND-IN FOR TIKTOK when a clip is drafted (recast pipeline, piece 19),
# for the e2e lane (E2E_FAKE_VIDEO_STORAGE=1) and a local demo
# (TIKTOK_DRAFT_STAND_IN=1). NEVER in production: there the real inbox upload
# runs, or the button says the keys are missing.
#
# The button, the record, the caption (read from ESPN, or the e2e lane's
# fixed season), the job and the states are all real. Only the two outside
# calls are replaced: no byte is read from R2 and nothing reaches TikTok. The
# stand-in's publish_id starts "stand-in-" and the attempt's facts say
# stand_in: true, so a demo draft can never be mistaken for one on the phone.
# The real upload is pinned by test/services/tiktok/inbox_upload_test.rb.
module TiktokDraftStandIn
  class Uploader
    def stand_in? = true

    def call(size:, read:)
      plan = Tiktok::InboxUpload.plan(size)
      publish_id = "stand-in-#{SecureRandom.hex(6)}"
      yield(:initialized, publish_id) if block_given?
      { publish_id:, plan: }
    end

    def status(_publish_id) = { "status" => "SEND_TO_USER_INBOX" }
  end

  class Reader
    def size(_key) = nil

    def read(_key, _offset, length) = "\0" * length
  end

  def self.install!
    Tiktok::DraftClip.uploader = Uploader.new
    Tiktok::DraftClip.reader = Reader.new
  end
end

if !Rails.env.production? && (ENV["TIKTOK_DRAFT_STAND_IN"] == "1" || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1"))
  Rails.application.config.to_prepare do
    TiktokDraftStandIn.install!
    # The e2e lane reads the same fixed season the X card's draft reads.
    Tiktok::DraftClip.fetch = Content::DraftXCopy.fetch if Rails.env.test?
    # The test adapter only records jobs; run the upload in-process so the
    # page can reach "In your TikTok drafts". Scoped to this one job.
    TiktokDraftJob.queue_adapter = :async if Rails.env.test?
  end
end

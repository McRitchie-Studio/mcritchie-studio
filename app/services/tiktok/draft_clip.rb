module Tiktok
  # A clip's primary version into the operator's TikTok drafts (recast
  # pipeline, piece 19). Both doors use it: the clip card's "Draft to TikTok"
  # button and bin/tiktok-draft through the API.
  #
  #   preview(clip)          what a draft would send: the version, the athlete
  #                          and team (Tiktok::ClipTeam) and the caption
  #                          (Tiktok::ClipCaption). Writes nothing, calls no TikTok.
  #   check!(clip)          every refusal, writing nothing; returns the preview
  #   record!(preview, by:)  records a TiktokDraft (queued) with that caption
  #                          and queues TiktokDraftJob
  #   request!(clip, by:)    both
  #   run(draft)             the job's work: read the version from R2 chunk by
  #                          chunk, inbox-upload it (Tiktok::InboxUpload), then
  #                          poll TikTok's status for up to POLL_FOR.
  #   refresh(draft)         one more status read for a draft still processing.
  #
  # A draft is private in the operator's TikTok inbox until he posts it from
  # the phone; nothing here publishes.
  class DraftClip
    POLL_FOR = 90 # seconds the job waits for TikTok to finish processing
    POLL_EVERY = 5
    # A draft still pending after this long is treated as dead, so a retry may run.
    STUCK_AFTER = 15 * 60

    Preview = Data.define(:clip, :version, :choice, :caption)

    class Refused < StandardError; end

    class << self
      # Stand-ins for TikTok and R2. nil means the real thing. Set in tests,
      # and by config/initializers/tiktok_draft_stand_in.rb for the e2e lane
      # and a local demo (TIKTOK_DRAFT_STAND_IN=1, never in production).
      attr_accessor :uploader, :reader, :fetch, :sleeper

      def stand_in? = !uploader.nil? && uploader.respond_to?(:stand_in?) && uploader.stand_in?

      # Can this server make a draft at all? The four TikTok keys, or a stand-in.
      def available? = !uploader.nil? || OAuthClient.runtime_creds_present?

      def unavailable_reason
        "the TikTok keys are not set on this server (TIKTOK_CLIENT_KEY, TIKTOK_CLIENT_SECRET, " \
          "TIKTOK_REFRESH_TOKEN, TIKTOK_OPEN_ID)"
      end
    end

    def initialize(uploader: self.class.uploader, reader: self.class.reader, fetch: self.class.fetch,
                   sleeper: self.class.sleeper, now: -> { Time.current })
      @uploader = uploader || InboxUpload.new
      @reader = reader || R2Reader.new
      @fetch = fetch
      @sleeper = sleeper || ->(s) { sleep(s) }
      @now = now
    end

    def preview(clip)
      version = clip.primary_version or raise Refused, "#{clip.name} has no generated version yet"
      choice = ClipTeam.new(clip).call
      team = choice.team
      caption = ClipCaption.new(
        team: X::PostDraft::Team.new(name: team.name, location: team.location, mascot: team.mascot, hashtag: team.hashtag),
        league: team.league, fetch: @fetch, now: @now.call
      ).call
      Preview.new(clip:, version:, choice:, caption:)
    rescue ClipTeam::Refused, ClipCaption::Error => e
      raise Refused, e.message
    end

    # Everything that would stop a draft, before anything is written: the
    # keys, an attempt already in flight, and the preview itself. Returns the
    # preview; raises Refused. A refusal is an answer, not an error to log.
    def check!(clip)
      raise Refused, self.class.unavailable_reason unless self.class.available?

      open = clip.tiktok_drafts.pending.where(created_at: (@now.call - STUCK_AFTER)..).last
      raise Refused, "a draft of #{clip.slug} is already #{open.state_label.downcase} (attempt #{open.id})" if open

      preview(clip)
    end

    # Records the attempt from a checked preview and queues the upload.
    def record!(pv, by: nil)
      draft = pv.clip.tiktok_drafts.create!(
        version_number: pv.version.number, version_object_key: pv.version.object_key, caption: pv.caption.text,
        byte_size: pv.version.byte_size, requested_by: by, state: "queued",
        facts: pv.caption.facts.merge(
          "athlete" => pv.choice.entry.person_name, "look" => pv.choice.entry.look_name,
          "athlete_rule" => pv.choice.rule, "team_slug" => pv.choice.team.slug, "team_from" => pv.choice.team_source,
          "exceptions" => pv.caption.exceptions, "stand_in" => self.class.stand_in?
        )
      )
      TiktokDraftJob.perform_later(draft.id)
      draft
    end

    def request!(clip, by: nil) = record!(check!(clip), by:)

    # The job's half. Only the run that moves the row off `queued` uploads, so
    # a queue that hands a dead worker's job to another never sends twice.
    def run(draft)
      claimed = TiktokDraft.where(id: draft.id, state: "queued").update_all(state: "uploading", updated_at: @now.call)
      return draft.reload unless claimed == 1

      draft.reload
      size = @reader.size(draft.version_object_key) || draft.byte_size
      result = @uploader.call(size:, read: ->(offset, length) { @reader.read(draft.version_object_key, offset, length) }) do |_step, publish_id|
        draft.update!(publish_id:)
      end
      draft.update!(publish_id: result[:publish_id], byte_size: size, chunk_count: result[:plan].count,
                    state: "processing", uploaded_at: @now.call)
      poll(draft)
    rescue InboxUpload::Error, R2Reader::Error => e
      fail!(draft, e.message)
    rescue StandardError => e
      # Never leave the row at `uploading`: record it, then let the job see it.
      fail!(draft, "#{e.class.name}: #{e.message}")
      raise
    end

    # Reads TikTok's status until it settles or POLL_FOR runs out; a draft
    # still processing then stays `processing` for a later refresh.
    def poll(draft)
      deadline = @now.call + POLL_FOR
      loop do
        refresh(draft)
        return draft unless draft.pending?
        return draft if @now.call >= deadline

        @sleeper.call(POLL_EVERY)
      end
    end

    # One status read. Settles the draft when TikTok has.
    def refresh(draft)
      return draft unless draft.state == "processing" && draft.publish_id.present?

      data = @uploader.status(draft.publish_id)
      status = data["status"].to_s
      attrs = { tiktok_status: status.presence, polled_at: @now.call }
      if InboxUpload::DELIVERED.include?(status)
        attrs.merge!(state: "delivered", finished_at: @now.call)
      elsif InboxUpload::FAILED.include?(status)
        attrs.merge!(state: "failed", finished_at: @now.call, fail_reason: data["fail_reason"].to_s.presence,
                     error: "TikTok could not process the upload: #{data['fail_reason'].presence || 'no reason given'}")
      end
      draft.update!(attrs)
      draft
    rescue InboxUpload::Error => e
      draft.update!(polled_at: @now.call, error: "status read failed: #{e.message}")
      draft
    end

    private

    def fail!(draft, message)
      draft.update!(state: "failed", error: message.to_s[0, 1_000], finished_at: @now.call)
      draft
    end

    # The version's bytes, a range at a time, from whichever store Studio::S3
    # points at (production reads the production bucket).
    class R2Reader
      class Error < StandardError; end

      def size(key)
        storage { client.head_object(bucket: Studio::S3.bucket, key: Studio::S3.full_key(key)).content_length }
      end

      def read(key, offset, length)
        storage do
          client.get_object(bucket: Studio::S3.bucket, key: Studio::S3.full_key(key),
                            range: "bytes=#{offset}-#{offset + length - 1}").body.read
        end
      end

      private

      def client = Studio::S3.client

      def storage
        require "aws-sdk-s3"
        yield
      rescue Studio::S3::NotConfigured
        raise Error, "object storage is not configured on this server"
      rescue Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError, Seahorse::Client::NetworkingError => e
        raise Error, "the version could not be read from storage (#{e.class.name.demodulize})"
      end
    end
  end
end

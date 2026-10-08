module Tiktok
  # A clip's primary version to the operator's TikTok inbox (recast
  # pipeline, piece 19). Both doors use it: the clip card's "Draft to TikTok"
  # button and bin/tiktok-draft through the API.
  #
  #   preview(clip)          what a draft would send: the version, the athlete
  #                          and team (Tiktok::ClipTeam) and the caption
  #                          (Tiktok::ClipCaption). Writes nothing, calls no TikTok.
  #   check!(clip)          every refusal, writing nothing; returns the preview
  #   record!(preview, by:)  under the clip's row lock, looks once more for an
  #                          attempt in flight, records a TiktokDraft (queued)
  #                          with that caption, then queues TiktokDraftJob
  #   request!(clip, by:)    both
  #   run(draft)             the job's work: read the version from R2 chunk by
  #                          chunk, inbox-upload it (Tiktok::InboxUpload), then
  #                          poll TikTok's status for up to POLL_FOR.
  #   refresh(draft)         one more status read for a draft TikTok holds.
  #
  # TikTok sends the operator an inbox notification; he opens it in the phone
  # app and posts it or saves it to Drafts. Nothing here publishes.
  #
  # ONE PRESS, ONE DRAFT. check! reads the attempts and then ESPN (three
  # requests, seconds), so two presses can both pass it before either records.
  # record! is therefore the gate: it takes the clip's row lock and looks
  # again, and every attempt is created there and nowhere else. The ESPN reads
  # stay outside the lock, so it is held for two queries. A unique index would
  # not do instead: an attempt pending past STUCK_AFTER is dead and must not
  # block the next one, which an index cannot say.
  #
  # ONCE THE BYTES ARE WITH TIKTOK, THE ATTEMPT IS NEVER `failed` BY US. Only
  # TikTok's own FAILED status fails it. Anything that breaks after the upload
  # returned (the status read, or our own write) leaves it `unknown`: the
  # draft may well be on the phone, and "failed" would invite a second one.
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

      refuse_if_in_flight!(clip)
      preview(clip)
    end

    # Records the attempt from a checked preview and queues the upload. The
    # check that passed may be seconds old, so this looks again with the clip's
    # row locked: of two presses, the second waits here, sees the first's
    # attempt and is refused (Refused, like any other refusal). The job is
    # queued after the lock's transaction commits, so it can find the row.
    def record!(pv, by: nil)
      draft = pv.clip.with_lock do
        refuse_if_in_flight!(pv.clip)
        TiktokDraft.create!(
          clip_slug: pv.clip.slug, version_number: pv.version.number, version_object_key: pv.version.object_key,
          caption: pv.caption.text, byte_size: pv.version.byte_size, requested_by: by, state: "queued",
          facts: pv.caption.facts.merge(
            "athlete" => pv.choice.entry.person_name, "look" => pv.choice.entry.look_name,
            "athlete_rule" => pv.choice.rule, "team_slug" => pv.choice.team.slug, "team_from" => pv.choice.team_source,
            "exceptions" => pv.caption.exceptions, "stand_in" => self.class.stand_in?
          )
        )
      end
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
      size, result = upload(draft)
      return draft unless result

      # Past this line the bytes are with TikTok: nothing below may fail the attempt.
      begin
        draft.update!(publish_id: result[:publish_id], byte_size: size, chunk_count: result[:plan].count,
                      state: "processing", uploaded_at: @now.call)
        poll(draft)
      rescue StandardError => e
        unknown!(draft, e, publish_id: result[:publish_id])
        raise
      end
    end

    # Reads TikTok's status until it settles or POLL_FOR runs out; a draft
    # still unsettled then keeps its state for a later refresh.
    def poll(draft)
      deadline = @now.call + POLL_FOR
      loop do
        refresh(draft)
        return draft unless draft.pending?
        return draft if @now.call >= deadline

        @sleeper.call(POLL_EVERY)
      end
    end

    # One status read. Settles the draft when TikTok has. A read that breaks
    # NEVER fails the attempt and never raises: TikTok unreachable leaves it
    # where it was with the reason, and anything else leaves it `unknown`. A
    # later read that works settles either.
    def refresh(draft)
      return draft unless TiktokDraft::WITH_TIKTOK.include?(draft.state) && draft.publish_id.present?

      data = @uploader.status(draft.publish_id)
      status = data["status"].to_s
      attrs = { tiktok_status: status.presence, polled_at: @now.call, error: nil }
      if InboxUpload::DELIVERED.include?(status)
        attrs.merge!(state: "delivered", finished_at: @now.call)
      elsif InboxUpload::FAILED.include?(status)
        attrs.merge!(state: "failed", finished_at: @now.call, fail_reason: data["fail_reason"].to_s.presence,
                     error: "TikTok could not process the upload: #{data['fail_reason'].presence || 'no reason given'}")
      else
        attrs[:state] = "processing" # TikTok answered: the status is known again
      end
      draft.update!(attrs)
      draft
    rescue InboxUpload::Error => e
      draft.update!(polled_at: @now.call, error: "status read failed: #{e.message}")
      draft
    rescue StandardError => e
      unknown!(draft, e)
    end

    private

    # The newest attempt of this clip still in flight, refused by name. An
    # attempt pending past STUCK_AFTER is dead and blocks nothing.
    def refuse_if_in_flight!(clip)
      open = TiktokDraft.pending.where(clip_slug: clip.slug, created_at: (@now.call - STUCK_AFTER)..).order(:id).last
      raise Refused, "a draft of #{clip.slug} is already #{open.state_label.downcase} (attempt #{open.id})" if open
    end

    # Sends the bytes. Returns [size, result], or [nil, nil] with the attempt
    # failed: until the uploader returns, TikTok does not have the whole file,
    # so `failed` is true and a new attempt is the right next step.
    def upload(draft)
      size = @reader.size(draft.version_object_key) || draft.byte_size
      result = @uploader.call(size:, read: ->(offset, length) { @reader.read(draft.version_object_key, offset, length) }) do |_step, publish_id|
        draft.update!(publish_id:)
      end
      [size, result]
    rescue InboxUpload::Error, R2Reader::Error => e
      fail!(draft, e.message)
      [nil, nil]
    rescue StandardError => e
      # Never leave the row at `uploading`: record it, then let the job see it.
      fail!(draft, "#{e.class.name}: #{e.message}")
      raise
    end

    def fail!(draft, message)
      draft.update!(state: "failed", error: message.to_s[0, 1_000], finished_at: @now.call)
      draft
    end

    # The upload finished and we cannot say how it went. Written straight to
    # the columns: the write that just broke may have left the record unsaved
    # or invalid, and this must land regardless.
    def unknown!(draft, error, publish_id: draft.publish_id)
      Rails.logger.warn("[tiktok-draft] attempt #{draft.id} uploaded, status unknown: #{error.class.name}: #{error.message}")
      draft.update_columns( # rubocop:disable Rails/SkipsModelValidations
        state: "unknown", publish_id:, uploaded_at: draft.uploaded_at || @now.call, polled_at: @now.call, updated_at: @now.call,
        error: "The upload reached TikTok, but its status could not be read (#{error.class.name}). #{TiktokDraft::UNKNOWN_STEP}: " \
               "it may already be there. Check TikTok reads the status again; do not draft this clip again until you have looked."
      )
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

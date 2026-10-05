module MusicVideos
  # Files the generated MP4 the operator uploaded back for one chunk as its
  # next numbered take: the object goes to R2 under the video's generated/
  # folder, the row records it, the take becomes current, and a pending
  # "request regenerate" on the chunk is cleared.
  #
  # The form upload rides a web request (the pattern Content::AttachVideo set),
  # so the ceiling is what a browser can send inside Heroku's 30-second window.
  class StoreTake
    MAX_BYTES = 100 * 1024 * 1024

    class Refused < StandardError; end
    # The bucket did not take the file. Nothing was recorded.
    class StorageFailed < StandardError; end

    def initialize(chunk, upload)
      @chunk = chunk
      @upload = upload
    end

    # Raises Refused with a sentence the page can show. Touches nothing.
    def validate!
      raise Refused, "only a chunk takes a generated file" unless @chunk.chunk?
      raise Refused, "choose the generated MP4 first" if @upload.blank? || !@upload.respond_to?(:tempfile)
      raise Refused, "that file is not an MP4" unless mp4?
      raise Refused, "that file is empty" if @upload.size.to_i.zero?
      raise Refused, "that MP4 is over #{MAX_BYTES / 1024 / 1024} MB" if @upload.size > MAX_BYTES
    end

    # The video row is locked from numbering the take to recording it, upload
    # included: two uploads for one chunk may never be handed the same number,
    # because the same number is the same object key and a take is never
    # overwritten. One operator, a few seconds; the lock is the cheap guard.
    def call
      validate!
      video = @chunk.music_video
      VideoChunkTake.transaction do
        video.lock!
        take = video.chunk_takes.build(chunk_ordinal: @chunk.ordinal, start_ms: @chunk.start_ms, end_ms: @chunk.end_ms,
                                       number: next_number(video), byte_size: @upload.size,
                                       original_filename: File.basename(@upload.original_filename.to_s).first(255),
                                       current_since: Time.current)
        take.object_key = ObjectKeys.take(source_key: video.source_object_key, ordinal: take.chunk_ordinal,
                                          start_ms: take.start_ms, end_ms: take.end_ms, number: take.number)
        raise Refused, take.errors.full_messages.to_sentence unless take.valid?

        # The IO itself, never `.read`: a take read into a string is dyno memory.
        self.class.store(key: take.object_key, body: @upload.tempfile.tap(&:rewind))
        take.save!
        take.make_current!
        @chunk.clear_regenerate! if @chunk.regenerate_requested?
        take
      end
    end

    # The one seam to object storage, so tests and the e2e lane can stand in
    # for the bucket. Private object: the page reads it back on a signed URL.
    def self.store(key:, body:)
      require "aws-sdk-s3"
      Studio::S3.upload(key: key, body: body, content_type: "video/mp4")
    rescue Studio::S3::NotConfigured
      raise StorageFailed, "object storage is not configured for this app"
    rescue Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError, Seahorse::Client::NetworkingError => e
      raise StorageFailed, "object storage did not take it (#{e.class.name.demodulize})"
    end

    private

    # Numbered across every take this chunk ordinal ever had on the video,
    # whatever window it was cut at: a number is never reused.
    def next_number(video)
      VideoChunkTake.where(music_video_slug: video.slug, chunk_ordinal: @chunk.ordinal).maximum(:number).to_i + 1
    end

    # By extension and by the file's own header (an MP4 opens with an ftyp
    # box); the browser's content type is not trusted either way.
    def mp4?
      return false unless File.extname(@upload.original_filename.to_s).casecmp?(".mp4")

      io = @upload.tempfile
      io.rewind
      head = io.read(12).to_s
      io.rewind
      head.byteslice(4, 4) == "ftyp"
    end
  end
end

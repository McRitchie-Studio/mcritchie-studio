module MusicVideos
  # Files the generated MP4 the operator uploaded (or dropped) back for one
  # clip of an alt video as its next numbered version: the object goes to R2
  # under the alt video's folder, the row records it, the version becomes
  # primary, and a pending "request regenerate" on the clip is cleared.
  # Piece 3's StoreTake, moved onto the clip.
  #
  # The form upload rides a web request (the pattern Content::AttachVideo set),
  # so the ceiling is what a browser can send inside Heroku's 30-second window.
  class StoreClipVersion
    MAX_BYTES = 100 * 1024 * 1024

    class Refused < StandardError; end
    # The bucket did not take the file. Nothing was recorded.
    class StorageFailed < StandardError; end

    def initialize(clip, upload)
      @clip = clip
      @upload = upload
    end

    # Raises Refused with a sentence the page can show. Touches nothing.
    def validate!
      raise Refused, "choose the generated MP4 first" if @upload.blank? || !@upload.respond_to?(:tempfile)
      raise Refused, "that file is not an MP4" unless mp4?
      raise Refused, "that file is empty" if @upload.size.to_i.zero?
      raise Refused, "that MP4 is over #{MAX_BYTES / 1024 / 1024} MB" if @upload.size > MAX_BYTES
    end

    # The alt video row is locked from numbering the version to recording it,
    # upload included: two uploads for one clip may never be handed the same
    # number, because the same number is the same object key and a version is
    # never overwritten. One operator, a few seconds; the lock is the cheap guard.
    def call
      validate!
      alt = @clip.alt_video
      AltVideoClipVersion.transaction do
        alt.lock!
        number = @clip.versions.maximum(:number).to_i + 1
        version = @clip.versions.build(
          number:, byte_size: @upload.size, primary_since: Time.current,
          original_filename: File.basename(@upload.original_filename.to_s).first(255),
          object_key: ObjectKeys.alt_clip_version(source_key: alt.music_video.source_object_key, alt_number: alt.number,
                                                  ordinal: @clip.chunk_ordinal, start_ms: @clip.start_ms,
                                                  end_ms: @clip.end_ms, number:)
        )
        raise Refused, version.errors.full_messages.to_sentence unless version.valid?

        # The IO itself, never `.read`: a version read into a string is dyno memory.
        self.class.store(key: version.object_key, body: @upload.tempfile.tap(&:rewind))
        version.save!
        version.make_primary!
        @clip.clear_regenerate! if @clip.regenerate_requested?
        version
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

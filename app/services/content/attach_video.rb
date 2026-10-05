class Content
  # Files the operator's uploaded MP4 for a video_post_x Content and records its
  # URL as final_video_url — the one field every later step reads the video from.
  #
  # The form upload rides a web request, so the ceiling here is what a browser
  # can send inside Heroku's 30-second window, not what X accepts.
  class AttachVideo
    MAX_BYTES = 100 * 1024 * 1024

    class Refused < StandardError; end

    def initialize(content, upload)
      @content = content
      @upload  = upload
    end

    # Raises Refused with a sentence the form can show. Touches nothing.
    def validate!
      raise Refused, "Attach the MP4 to post." if @upload.blank?
      raise Refused, "That file is not an MP4." unless mp4?
      raise Refused, "That MP4 is over #{MAX_BYTES / 1024 / 1024} MB." if @upload.size > MAX_BYTES
    end

    def call
      validate!
      # The IO itself, never `.read`: a 100 MB upload read into a string is a
      # fifth of a dyno's memory for the length of the request.
      url = self.class.store(key: "video_posts/#{@content.slug}.mp4", body: @upload.tempfile)
      raise Refused, "The video was stored but has no public URL, so nothing can post it." if url.blank?

      @content.update!(final_video_url: url)
      @content
    end

    # The one seam to object storage, so the e2e lane can stand in for the bucket.
    def self.store(key:, body:)
      Studio::S3.upload(key: key, body: body, content_type: "video/mp4",
                        cache_control: "public, max-age=31536000, immutable")
    end

    private

    def mp4?
      File.extname(@upload.original_filename.to_s).casecmp?(".mp4") && @upload.content_type.to_s == "video/mp4"
    end
  end
end

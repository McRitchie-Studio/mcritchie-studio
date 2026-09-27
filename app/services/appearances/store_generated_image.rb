require "base64"
require "net/http"
require "securerandom"

module Appearances
  # PUT A GENERATED IMAGE IN OUR OWN S3, and hand back OUR url.
  #
  # TWO REASONS, and the first one is not optional.
  #
  # 1. A DATA URI CANNOT BE THE STORED VALUE. The OpenAI adapter returns the image
  #    as BASE64 — a ten-panel sheet is a couple of megabytes, so roughly 3 MB of
  #    base64. Writing that into `artifacts.image_url` puts multiple megabytes in a
  #    varchar and then inlines it into the HTML of every page that lists the
  #    artifact. The column holds a URL; this is what makes one.
  #
  # 2. A VENDOR CDN URL IS NOT A LIBRARY. fal hands back a `v3b.fal.media` link
  #    whose lifetime is theirs, not ours. The operator's whole premise is a
  #    library he keeps and compares across generators — one that 404s in a month
  #    is not a library. Appearances::ReferenceImages already argues this for the
  #    INPUT side ("it is OUR copy we hand out, so the identity does not depend on
  #    a third party's hotlinking policy"); this is the same argument for the
  #    output side.
  #
  # SO IT ACCEPTS BOTH SHAPES — a `data:` URI or an http(s) URL — and always
  # answers with a URL in our bucket. One door, because the caller should not
  # branch on which generator ran; that is the registry's whole point.
  #
  # IT RAISES RATHER THAN DEGRADING. By the time this runs the image has been PAID
  # FOR, so a silent fallback to the vendor URL would quietly produce exactly the
  # rotting library described above, and a silent fallback to the data URI would
  # produce the multi-megabyte column. A failure here is worth an operator seeing.
  class StoreGeneratedImage
    PREFIX = "character-sheets".freeze
    MAX_BYTES = 25 * 1024 * 1024

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 60

    DATA_URI = %r{\Adata:(?<type>[\w/\-.+]+);base64,(?<data>.+)\z}m

    class StoreFailed < StandardError; end

    def self.call(source, **kwargs) = new(source, **kwargs).call

    def initialize(source, person_slug:, clock: Time)
      @source = source.to_s
      @person_slug = person_slug.to_s.presence || "unknown"
      @clock = clock
    end

    def call
      raise StoreFailed, "nothing to store" if @source.blank?

      bytes, content_type = decode
      if bytes.bytesize > MAX_BYTES
        raise StoreFailed, "generated image is #{bytes.bytesize} bytes, over the #{MAX_BYTES} cap"
      end

      key = build_key(content_type)
      Studio::S3.upload(key: key, body: bytes, content_type: content_type)
      Studio::S3.url(key: key)
    rescue StoreFailed
      raise
    rescue StandardError => e
      raise StoreFailed, "could not store the generated image: #{e.class}: #{e.message}"
    end

    private

    def decode
      if (match = DATA_URI.match(@source))
        data = Base64.decode64(match[:data])
        raise StoreFailed, "the data URI decoded to nothing" if data.empty?

        [data, match[:type]]
      else
        fetch_remote
      end
    end

    def fetch_remote
      uri = URI.parse(@source)
      raise StoreFailed, "#{@source.inspect} is not an http(s) URL" unless uri.is_a?(URI::HTTP)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      raise StoreFailed, "#{@source} answered HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      [response.body.to_s, response["content-type"].presence || "image/png"]
    end

    # PERSON-SCOPED AND RANDOM. Scoped so the bucket is browsable by subject the
    # way the headshots are; RANDOM rather than derived from the artifact slug so
    # the upload can happen BEFORE the row exists — a failed upload then leaves no
    # half-built artifact pointing at an object that was never written.
    def build_key(content_type)
      ext = content_type.to_s.split("/").last.presence || "png"
      ext = "jpg" if ext == "jpeg"
      "#{PREFIX}/#{@person_slug}/#{@clock.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4)}.#{ext}"
    end
  end
end

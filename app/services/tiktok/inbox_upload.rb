require "net/http"
require "uri"
require "json"

module Tiktok
  # Puts one MP4 into a TikTok user's drafts ("inbox") through the Content
  # Posting API, sending the bytes ourselves: source FILE_UPLOAD, in chunks
  # (recast pipeline, piece 19).
  #
  # WHY FILE_UPLOAD, NOT PULL_FROM_URL. PULL_FROM_URL makes TikTok fetch the
  # file, and TikTok only fetches from a domain or URL prefix verified on the
  # developer app. The clip versions live in R2 behind short-lived signed URLs
  # on the bucket's own host, which is not verified there (only the hub's
  # mcritchie.studio prefix ever was, for the OAuth callback). FILE_UPLOAD needs
  # no verified domain: the server reads the object from R2 one chunk at a time
  # and PUTs each chunk to the upload URL TikTok hands back.
  #
  # TikTok's chunk rules (Content Posting API, "Media Transfer Guide"):
  #   - a file under 5 MB goes as ONE chunk (chunk_size = the file's size);
  #   - otherwise every chunk is 5 to 64 MB, and the count is the size divided
  #     by the chunk size, ROUNDED DOWN, so the last chunk carries the
  #     remainder and may run past chunk_size (up to 128 MB);
  #   - chunks go in order, each with Content-Range "bytes first-last/total";
  #   - at most 1,000 chunks; the upload URL lasts one hour.
  # We send 10 MB chunks, and a file of 10 MB or less in one: a 25 s clip is
  # one to three chunks. MAX_BYTES is our own cap, far below TikTok's 4 GB.
  #
  # The inbox upload takes NO caption: TikTok's inbox endpoint accepts only the
  # source. The operator pastes the caption when he posts from the phone.
  class InboxUpload
    INIT_URL = PostMedia::INBOX_INIT_URL
    STATUS_URL = PostMedia::STATUS_URL
    CREATOR_INFO_URL = "https://open.tiktokapis.com/v2/post/publish/creator_info/query/".freeze

    MB = 1024 * 1024
    MIN_CHUNK = 5 * MB
    CHUNK = 10 * MB
    MAX_CHUNK = 64 * MB
    MAX_FINAL_CHUNK = 128 * MB
    MAX_CHUNKS = 1_000
    MAX_BYTES = 512 * MB

    # TikTok's own publish statuses, by what they mean for a draft.
    DELIVERED = %w[SEND_TO_USER_INBOX PUBLISH_COMPLETE].freeze
    FAILED = %w[FAILED].freeze

    Plan = Data.define(:video_size, :chunk_size, :count) do
      # [[first_byte, last_byte], ...], the last chunk running to the end.
      def ranges
        (0...count).map do |i|
          first = i * chunk_size
          [first, i == count - 1 ? video_size - 1 : first + chunk_size - 1]
        end
      end

      def to_source_info
        { source: "FILE_UPLOAD", video_size:, chunk_size:, total_chunk_count: count }
      end
    end

    class Error < StandardError
      attr_reader :code

      def initialize(message, code: nil)
        super(message)
        @code = code
      end
    end

    # The chunking TikTok will accept for a file of this many bytes.
    def self.plan(video_size)
      size = Integer(video_size)
      raise Error, "the file is empty" unless size.positive?
      raise Error, "the file is #{size / MB} MB, over this uploader's #{MAX_BYTES / MB} MB" if size > MAX_BYTES
      return Plan.new(video_size: size, chunk_size: size, count: 1) if size <= CHUNK

      Plan.new(video_size: size, chunk_size: CHUNK, count: size / CHUNK)
    end

    # http: (verb, url, headers, body) -> [status Integer, body String]; nil is Net::HTTP.
    # token: -> access token; nil is Tiktok::OAuthClient.access_token.
    def initialize(http: nil, token: nil)
      @http = http || method(:net_http)
      @token = token || -> { OAuthClient.access_token }
    end

    # Opens an inbox upload for `size` bytes and sends them, reading each chunk
    # with read.call(offset, length). Returns { publish_id:, plan: }. Raises
    # Error naming the step that failed; a failure after init still carries
    # the publish_id in its message so the attempt can record it.
    def call(size:, read:)
      plan = self.class.plan(size)
      data = post_json(INIT_URL, { source_info: plan.to_source_info })
      publish_id = data["publish_id"].to_s
      upload_url = data["upload_url"].to_s
      raise Error, "TikTok's init answered without a publish_id or upload URL" if publish_id.empty? || upload_url.empty?

      yield(:initialized, publish_id) if block_given?
      plan.ranges.each_with_index do |(first, last), i|
        bytes = read.call(first, last - first + 1)
        raise Error, "chunk #{i + 1} read #{bytes.bytesize} bytes, expected #{last - first + 1}" unless bytes.bytesize == last - first + 1

        put_chunk(upload_url, bytes, first, last, plan.video_size, i + 1, plan.count)
      end
      { publish_id:, plan: }
    end

    # One read of TikTok's publish status: { "status", "fail_reason", ... }.
    def status(publish_id) = post_json(STATUS_URL, { publish_id: publish_id })

    # The account the token posts as, and what TikTok lets it do.
    def creator_info = post_json(CREATOR_INFO_URL, {})

    private

    def put_chunk(url, bytes, first, last, total, number, count)
      headers = { "Content-Type" => "video/mp4", "Content-Length" => bytes.bytesize.to_s,
                  "Content-Range" => "bytes #{first}-#{last}/#{total}" }
      code, body = @http.call(:put, url, headers, bytes)
      return if (200..299).cover?(code)

      raise Error.new("TikTok refused chunk #{number} of #{count} (HTTP #{code}): #{error_text(body)}", code: code.to_s)
    end

    def post_json(url, payload)
      headers = { "Authorization" => "Bearer #{@token.call}", "Content-Type" => "application/json; charset=UTF-8" }
      code, body = @http.call(:post, url, headers, JSON.generate(payload))
      json = parse(body)
      err = json["error"].is_a?(Hash) ? json["error"] : {}
      unless (200..299).cover?(code) && err["code"].to_s == "ok"
        raise Error.new("TikTok #{URI(url).path} answered HTTP #{code} #{err['code']}: #{err['message'].to_s[0, 300]}".squeeze(" "),
                        code: err["code"].to_s.presence || code.to_s)
      end
      json["data"] || {}
    end

    def parse(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end

    def error_text(body)
      err = parse(body)["error"]
      err.is_a?(Hash) ? "#{err['code']} #{err['message']}".strip : body.to_s[0, 200]
    end

    def net_http(verb, url, headers, body)
      uri = URI(url)
      req = (verb == :put ? Net::HTTP::Put : Net::HTTP::Post).new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 120) do |h|
        h.request(req)
      end
      [resp.code.to_i, resp.body.to_s]
    rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error.new("could not reach TikTok (#{e.class.name})", code: "network")
    end
  end
end

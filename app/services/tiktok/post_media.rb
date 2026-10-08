require "net/http"
require "uri"
require "json"

module Tiktok
  # Posts a video to TikTok via the Content Posting API.
  #
  # Two publish modes:
  #   :direct_post (default) — publishes to the public feed immediately
  #   :inbox                 — sends to drafts, user finishes posting in app
  #                             (lets us attach trending sounds manually before publishing)
  #
  # Source: PULL_FROM_URL pointed at our public-read S3 MP4. TikTok fetches
  # the file server-side (no chunked upload needed). Bucket policies on
  # mcritchie-studio-{dev,production} already allow public-read.
  #
  # Music: optional :music_id (Commercial Music Library, requires a TikTok
  # Business account). Without it, the post has no soundtrack — finish in
  # the app via :inbox mode if you want a trending sound.
  class PostMedia
    DIRECT_INIT_URL  = "https://open.tiktokapis.com/v2/post/publish/video/init/".freeze
    INBOX_INIT_URL   = "https://open.tiktokapis.com/v2/post/publish/inbox/video/init/".freeze
    STATUS_URL       = "https://open.tiktokapis.com/v2/post/publish/status/fetch/".freeze

    PRIVACY_LEVELS = %w[
      PUBLIC_TO_EVERYONE
      MUTUAL_FOLLOW_FRIENDS
      FOLLOWER_OF_CREATOR
      SELF_ONLY
    ].freeze

    class Error < StandardError; end
    class NotConfigured < Error; end

    def initialize(text:, video_url:, publish_type: :direct_post, music_id: nil,
                   privacy_level: "PUBLIC_TO_EVERYONE", cover_timestamp_ms: 1000)
      @text               = text.to_s
      @video_url          = video_url.to_s
      @publish_type       = publish_type.to_sym
      @music_id           = music_id.presence
      @privacy_level      = privacy_level
      @cover_timestamp_ms = cover_timestamp_ms
      raise Error, "video_url required" if @video_url.blank?
      raise Error, "invalid publish_type #{@publish_type}" unless %i[direct_post inbox].include?(@publish_type)
      unless PRIVACY_LEVELS.include?(@privacy_level)
        raise Error, "invalid privacy_level #{@privacy_level}"
      end
    end

    # Returns { publish_id:, post_url: nil_for_inbox } — for direct_post the
    # publish_id can later be resolved to a public URL via STATUS_URL once
    # processing succeeds. We don't poll-to-public-URL yet because TikTok's
    # status endpoint returns a `publicaly_available_post_id` only after the
    # video clears moderation, which can take 30s–minutes.
    #
    # A direct post publishes, so it needs video.publish: a connection
    # authorized for drafts only is refused here, before TikTok is asked
    # (Tiktok::OAuthClient::MissingScope, which says so in plain words).
    def call
      OAuthClient.ensure_direct_post! if @publish_type == :direct_post
      json = init_publish
      publish_id = json.dig("data", "publish_id") or raise Error, "init missing publish_id: #{json.inspect}"
      { publish_id: publish_id, post_url: nil }
    end

    # Polls the publish status until it succeeds, fails, or times out. Returns
    # the final status hash. Optional — direct_post can succeed without polling
    # since TikTok's pipeline is async.
    def fetch_status(publish_id, max_wait: 240)
      deadline = Time.now + max_wait
      loop do
        json = post_json(STATUS_URL, { publish_id: publish_id })
        status = json.dig("data", "status")
        case status
        when "PUBLISH_COMPLETE", "INBOX_DELIVERED" then return json
        when "FAILED"                              then raise Error, "publish failed: #{json.inspect}"
        when "PROCESSING_UPLOAD", "PROCESSING_DOWNLOAD", "SEND_TO_USER_INBOX"
          raise Error, "status timed out after #{max_wait}s" if Time.now > deadline
          sleep 3
        else
          # Unknown / transitional — keep polling until deadline.
          raise Error, "status timed out (last: #{status.inspect})" if Time.now > deadline
          sleep 3
        end
      end
    end

    private

    def init_publish
      url = @publish_type == :inbox ? INBOX_INIT_URL : DIRECT_INIT_URL
      body = build_init_body
      post_json(url, body)
    end

    def build_init_body
      source_info = { source: "PULL_FROM_URL", video_url: @video_url }
      return { source_info: source_info } if @publish_type == :inbox

      post_info = {
        title:                   @text,
        privacy_level:           @privacy_level,
        disable_duet:            false,
        disable_comment:         false,
        disable_stitch:          false,
        video_cover_timestamp_ms: @cover_timestamp_ms
      }
      post_info[:music_id] = @music_id if @music_id
      { post_info: post_info, source_info: source_info }
    end

    def post_json(url, body)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{Tiktok::OAuthClient.access_token}"
      req["Content-Type"]  = "application/json; charset=UTF-8"
      req.body = JSON.generate(body)
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      json = JSON.parse(resp.body || "{}")
      unless resp.is_a?(Net::HTTPSuccess) && json.dig("error", "code").to_s == "ok"
        raise Error, "TikTok #{uri.path} failed (#{resp.code}): #{resp.body}"
      end
      json
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "tempfile"
require "uri"
require_relative "op_vaults"
require_relative "../../lib/music_videos/credit_parser"
require_relative "../../lib/music_videos/object_keys"
require_relative "../../lib/music_videos/vtt_timing"

# The agent side of `digest video <url>` (docs/agents/agents/pokemon/sops/digest-video.md):
# download → H.264 MP4 → R2 → POST /api/v1/music_videos. It runs where the
# download works (the operator's Mac); the app itself holds nothing Mac-specific.
# Lyric text never leaves this process: captions become timings here.
module DigestVideo
  class Failure < StandardError; end

  KINDS = %w[music_video cinematic].freeze # MusicVideo::KINDS; the hub refuses any other

  H264 = "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]"
  TIKTOK_H264 = "b[vcodec^=h264]/b[vcodec^=avc1]" # TikTok serves muxed files; the rest are H.265
  # No height cap: a reel is portrait (720x1280, 1080x1920), which `height<=1080` shuts out.
  INSTAGRAM_H264 = "bv*[vcodec^=avc1]+ba/b[vcodec^=avc1]/b[vcodec^=h264]"
  ANY = "bv*[height<=1080]+ba/b[height<=1080]/b"
  INSTAGRAM_ANY = "bv*+ba/b"
  R2_ITEM = "r2.mcritchie-studio"
  TARGETS = {
    false => { bucket: "mcritchie-studio-dev", suffix: "dev", api: "http://localhost:3000" },
    true => { bucket: "mcritchie-studio-production", suffix: "prod", api: "https://mcritchie.studio" }
  }.freeze

  # The stored info.json keeps only these. Everything else is dropped: the
  # description, tags and chapters can quote lyrics, and formats, thumbnails
  # and caption tracks carry signed URLs that embed the operator's public IP.
  INFO_ALLOWLIST = %w[id title uploader channel channel_id upload_date duration webpage_url
                      extractor width height fps vcodec acodec].freeze
  # A TikTok title is the caption, free text: dropped. uploader_id keeps the
  # creator findable after a handle change.
  TIKTOK_INFO_ALLOWLIST = (INFO_ALLOWLIST - %w[title] + %w[uploader_id]).freeze
  # An Instagram title is "Video by <handle>" or free text; the caption is the description.
  INSTAGRAM_INFO_ALLOWLIST = TIKTOK_INFO_ALLOWLIST
  CANONICAL_PAGE = %r{\Ahttps://(?:www\.)?youtube\.com/watch\?v=[\w-]{11}\z}
  TIKTOK_HOSTS = %w[tiktok.com vm.tiktok.com vt.tiktok.com].freeze
  TIKTOK_PAGE = %r{\Ahttps://www\.tiktok\.com/@[\w.-]+/video/(\d+)\z}
  # /reel/<code>, /reels/<code>, /p/<code>, /tv/<code>, each also under /<handle>/.
  INSTAGRAM_POST = %r{\A(?:/[^/]+)?/(p|tv|reels?)/([\w-]+)}
  # yt-dlp's own words when Instagram wants a session (measured 2026-10-04).
  LOGIN_WALL = /empty media response|cookies-from-browser|login required/i
  # Where yt-dlp keeps the session it was lent; never left in a downloaded info.json.
  SESSION_KEYS = %w[cookies http_headers].freeze
  CREDIT_WORDS = 4 # a longer "ft. …" run is caption prose, not a name
  QUERY_URL = %r{https?://\S*\?}

  module_function

  def target(production:) = TARGETS.fetch(production ? true : false)

  def platform_for(url)
    host = URI.parse(url.to_s).host.to_s.downcase.sub(/\A(?:www|m|music)\./, "")
    case host
    when "youtube.com", "youtu.be" then "youtube"
    when *TIKTOK_HOSTS then "tiktok"
    when "instagram.com" then "instagram"
    else raise Failure, "unsupported host #{host.inspect}: ask Alex"
    end
  rescue URI::InvalidURIError
    raise Failure, "not a URL: #{url}"
  end

  def info_allowlist(platform)
    { "tiktok" => TIKTOK_INFO_ALLOWLIST, "instagram" => INSTAGRAM_INFO_ALLOWLIST }.fetch(platform, INFO_ALLOWLIST)
  end

  # Allowlisted scalars only; a URL with a query string survives only as the canonical watch page.
  def sanitize_info(info, platform: "youtube")
    info.slice(*info_allowlist(platform)).select do |key, value|
      next false unless value.is_a?(String) || value.is_a?(Numeric)
      next true unless value.is_a?(String) && value.match?(QUERY_URL)

      key == "webpage_url" && value.match?(CANONICAL_PAGE)
    end
  end

  # The id is in a page URL; a short link (vm.tiktok.com) gets it from info.json.
  def tiktok_id(url) = URI.parse(url).path[%r{/video/(\d+)}, 1]

  # A share link (/share/reel/<token>) carries no shortcode, and yt-dlp refuses it.
  def instagram_id(url)
    path = URI.parse(url).path.to_s
    if path.start_with?("/share/")
      raise Failure, "an Instagram share link has no post id: open it and paste the /reel/ or /p/ URL it lands on"
    end

    path[INSTAGRAM_POST, 2] or raise Failure, "no Instagram post id in #{url}: paste a /reel/, /p/ or /tv/ URL"
  end

  # The post's page without the handle prefix or the tracking query (?igsh=…).
  def instagram_page(url, id)
    kind = URI.parse(url).path.to_s[INSTAGRAM_POST, 1].to_s.sub(/\Areels\z/, "reel")
    "https://www.instagram.com/#{kind.empty? ? 'p' : kind}/#{id}/"
  end

  def source_id(platform, url)
    case platform
    when "tiktok" then tiktok_id(url)
    when "instagram" then instagram_id(url)
    else youtube_id(url)
    end
  end

  def login_wall?(err) = err.to_s.match?(LOGIN_WALL)

  # Drops the lent session from every info.json yt-dlp wrote in dir.
  def scrub_session(dir)
    Dir.glob(File.join(dir, "*.info.json")).each do |path|
      File.write(path, JSON.generate(without_session(JSON.parse(File.read(path)))))
    end
  end

  def without_session(node)
    case node
    when Hash then node.except(*SESSION_KEYS).transform_values { |v| without_session(v) }
    when Array then node.map { |v| without_session(v) }
    else node
    end
  end

  def tiktok_credits(info)
    creator_credits([info["channel"], info["creator"], info["uploader"]], info["title"])
  end

  # Instagram's uploader is the display name and its channel the handle.
  def instagram_credits(info) = creator_credits([info["uploader"], info["channel"]], info["description"])

  # The creator, then feat.-style names from the caption's first line. The
  # caption itself is never kept: only names the parser pulls out of it.
  def creator_credits(names, caption)
    creator = names.map { |n| n.to_s.strip }.find { |n| !n.empty? }
    return [] unless creator # a caption name is never the primary

    caption = caption.to_s.lines.first.to_s.gsub(/#\S+/, "").gsub(/@([\w.]+)/, '\\1').squeeze(" ").strip
    featured = MusicVideos::CreditParser.new.parse(title: caption).featured
                                        .reject { |n| n.split.size > CREDIT_WORDS }
    [creator, *featured].compact.uniq(&:downcase)
  end

  def youtube_id(url)
    uri = URI.parse(url)
    id = URI.decode_www_form(uri.query.to_s).to_h["v"] ||
         uri.path[%r{\A/(?:shorts/|embed/|live/)?([\w-]{11})}, 1]
    id or raise Failure, "no video id in #{url}"
  end

  def shell
    lambda do |*cmd|
      out, err, status = Open3.capture3(*cmd)
      [out, err, status.success?]
    rescue Errno::ENOENT
      raise Failure, "#{File.basename(cmd.first)} not found"
    end
  end

  # One run: download (or reuse --from-dir), make it playable, store, record.
  class Runner
    def initialize(workdir:, shell:, storage:, api:, out: $stdout, from_dir: nil, dry_run: false,
                   encoder: "libx264", ytdlp: "yt-dlp", bucket: "mcritchie-studio-dev", cookies_from_browser: nil,
                   kind: "music_video")
      raise Failure, "kind must be one of: #{KINDS.join(', ')}" unless KINDS.include?(kind)

      @kind = kind
      @workdir = workdir
      @shell = shell
      @storage = storage
      @api = api
      @out = out
      @from_dir = from_dir
      @dry_run = dry_run
      @encoder = encoder
      @ytdlp = ytdlp
      @bucket = bucket
      @cookies_from_browser = cookies_from_browser
    end

    def call(url)
      platform = DigestVideo.platform_for(url)
      id = DigestVideo.source_id(platform, url)
      dir = @from_dir || File.join(@workdir, id || short_code(url)).tap { |d| FileUtils.mkdir_p(d) }
      download(url, dir, platform) unless @from_dir

      info = JSON.parse(File.read(find(dir, id.to_s, ".info.json")))
      if info["_type"] == "playlist"
        raise Failure, "#{url} is a post with #{info['playlist_count'] || 'several'} videos; a digest takes one: ask Alex"
      end

      id ||= info["id"].to_s
      mp4 = playable(find(dir, id, ".mp4"))
      vtts = Dir.glob(File.join(dir, "*#{id}*.vtt"))
      timing = MusicVideos::VttTiming.parse(vtts.min && File.read(vtts.min))
      payload = fields(platform, info, url, id)
      info = info.merge("webpage_url" => payload[:source_url]) if platform == "instagram"
      keys = object_keys(payload)
      payload.merge!(kind: @kind, platform: platform, source_id: id, duration_ms: duration_ms(mp4),
                     source_object_key: keys.source_mp4, info_object_key: keys.info_json, caption_timing: timing)
      return report_dry_run(payload, mp4) if @dry_run

      @api.authenticate # before any upload, so a failed login leaves nothing in R2
      store(keys, mp4, DigestVideo.sanitize_info(info, platform: platform))
      data = @api.create(payload)
      FileUtils.rm_f(vtts) # lyric text; kept until recorded so a --from-dir retry still has timings
      report(data, payload)
      data
    end

    private

    def fields(platform, info, url, id)
      case platform
      when "tiktok" then tiktok_fields(info, id)
      when "instagram" then instagram_fields(info, url, id)
      else youtube_fields(info, url, id)
      end
    end

    def youtube_fields(info, url, _id)
      { source_url: info["webpage_url"] || url, title: info["title"], uploader: info["uploader"],
        credited_artists: Array(info["artists"]),
        credits: [info["title"], info["uploader"], info["artists"] || info["artist"].to_s.split(", ")] }
    end

    # The caption never leaves: the record's title is "TikTok <id>", and the
    # hub reads credits from credited_artists (creator first, then feat. names).
    def tiktok_fields(info, id)
      artists = DigestVideo.tiktok_credits(info)
      raise Failure, "no creator in the TikTok info.json for #{id}" if artists.empty?

      page = info["webpage_url"].to_s
      page = "https://www.tiktok.com/@#{info['uploader']}/video/#{id}" unless page.match?(TIKTOK_PAGE)
      { source_url: page, title: "TikTok #{id}", uploader: info["uploader"], credited_artists: artists,
        credits: ["TikTok #{id}", nil, artists] }
    end

    # As for a TikTok: the title is "Instagram <shortcode>" and the caption stays here.
    def instagram_fields(info, url, id)
      artists = DigestVideo.instagram_credits(info)
      raise Failure, "no creator in the Instagram info.json for #{id}" if artists.empty?

      { source_url: DigestVideo.instagram_page(url, id), title: "Instagram #{id}", uploader: info["channel"],
        credited_artists: artists, credits: ["Instagram #{id}", nil, artists] }
    end

    # Same parse the hub runs, so the key matches the record's credits.
    def object_keys(payload)
      title, uploader, artists = payload.delete(:credits)
      credits = MusicVideos::CreditParser.new.parse(title: title, uploader: uploader, artists: artists)
      MusicVideos::ObjectKeys.new(primary: credits.primary, featured: credits.featured, song: credits.song)
    end

    def short_code(url) = URI.parse(url).path.scan(/[\w-]+/).last || "tiktok"

    def download(url, dir, platform)
      @out.puts "downloading #{url} (H.264 first)"
      instagram = platform == "instagram"
      subs = platform == "youtube" ? ["--write-subs", "--write-auto-subs", "--sub-format", "vtt", "--sub-langs", "en.*,en"] : []
      session = @cookies_from_browser ? ["--cookies-from-browser", @cookies_from_browser] : []
      common = [*session, "--merge-output-format", "mp4", "--write-info-json", *subs, "-P", dir,
                "-o", "%(id)s.%(ext)s", url]
      h264 = { "tiktok" => TIKTOK_H264, "instagram" => INSTAGRAM_H264 }.fetch(platform, H264)
      _o, err, ok = @shell.call(@ytdlp, "-f", h264, *common)
      unless ok
        raise Failure, login_wall(err) if DigestVideo.login_wall?(err) # a second try would only spend the rate limit

        @out.puts "no H.264 format (#{err.to_s.lines.last&.strip}); downloading best and converting"
        _o, err, ok = @shell.call(@ytdlp, "-f", instagram ? INSTAGRAM_ANY : ANY, *common)
        raise Failure, "yt-dlp failed: #{err.to_s.lines.last&.strip}" unless ok
      end
    ensure
      DigestVideo.scrub_session(dir) if @cookies_from_browser
    end

    def login_wall(err)
      line = err.to_s.lines.grep(/ERROR/).last.to_s[/ERROR:\s*(.+?\.)(?:\s|\z)/, 1] || err.to_s.lines.last.to_s.strip[0, 160]
      return "the site refused the download even with the #{@cookies_from_browser} session: #{line}" if @cookies_from_browser

      "the site wants a login (#{line}); rerun with --cookies-from-browser chrome"
    end

    def find(dir, id, ext)
      Dir.glob(File.join(dir, "*#{id}*#{ext}")).reject { |p| p.end_with?(".h264.mp4") }.min or
        raise Failure, "no #{ext} for #{id} in #{dir}"
    end

    # QuickTime plays H.264 + AAC. Anything else (VP9, Opus) is re-encoded;
    # audio goes to AAC, never copied, since Opus in MP4 will not play.
    def playable(mp4)
      video, audio = codecs(mp4)
      raise Failure, "#{File.basename(mp4)} has no audio track; a music video needs one" unless audio
      return mp4 if video == "h264" && audio == "aac"

      out = mp4.sub(/\.mp4\z/, ".h264.mp4")
      @out.puts "converting #{video}/#{audio} → h264/aac with #{@encoder}"
      rate = @encoder == "libx264" ? ["-crf", "18", "-preset", "medium"] : ["-b:v", "8M"]
      _o, err, ok = @shell.call("ffmpeg", "-y", "-v", "error", "-i", mp4, "-c:v", @encoder, *rate,
                                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out)
      raise Failure, "ffmpeg failed: #{err.to_s.lines.last&.strip}" unless ok

      out
    end

    def codecs(mp4)
      streams = probe(mp4)["streams"] || []
      %w[video audio].map { |type| streams.find { |s| s["codec_type"] == type }&.fetch("codec_name", nil) }
    end

    def duration_ms(mp4) = (probe(mp4).dig("format", "duration").to_f * 1000).round

    def probe(mp4)
      out, err, ok = @shell.call("ffprobe", "-v", "error", "-show_entries",
                                 "stream=codec_type,codec_name:format=duration", "-of", "json", mp4)
      raise Failure, "ffprobe failed: #{err}" unless ok

      JSON.parse(out)
    end

    def store(keys, mp4, stored_info)
      @out.puts "uploading to r2://#{@bucket}/#{keys.source_mp4}"
      @storage.put(keys.source_mp4, mp4, "video/mp4")
      Tempfile.create(["info", ".json"]) do |file|
        file.write(JSON.generate(stored_info))
        file.flush
        @storage.put(keys.info_json, file.path, "application/json")
      end
    end

    def report_dry_run(payload, mp4)
      @out.puts "dry run: would upload #{mp4} to r2://#{@bucket}/#{payload[:source_object_key]}"
      @out.puts JSON.pretty_generate(payload.merge(caption_timing: summary(payload[:caption_timing])))
      payload
    end

    def report(data, payload)
      @out.puts "digested #{data['slug']} (#{payload[:duration_ms]} ms, #{summary(payload[:caption_timing])})"
      @out.puts "  key: r2://#{@bucket}/#{payload[:source_object_key]}"
      Array(data["artists"]).each { |a| @out.puts "  #{a['role']}: #{a['name']} (#{a['slug']}, #{a['kind']})" }
      Array(data["unresolved_credits"]).each do |c|
        @out.puts "  UNRESOLVED #{c['role']}: #{c['name']} (#{c['reason']}); fix in the cast step"
      end
    end

    def summary(timing) = "#{timing['cues'].size} cues, #{timing['sections'].size} sections"
  end

  # Credentials come from 1Password through bin/secret; no value is printed.
  def secret(item, field)
    value, err, ok = Open3.capture3(File.expand_path("../secret", __dir__), OpVaults.vault, item, field)
    raise Failure, "1Password read failed for #{item}/#{field}: #{err.strip}" unless ok

    value
  end

  # R2 over the S3 API. Multipart upload for large files; fails loudly.
  class R2Storage
    def initialize(bucket:, suffix:)
      @bucket = bucket
      @suffix = suffix
    end

    def get(key, path)
      require "aws-sdk-s3"
      client.get_object(bucket: @bucket, key: key, response_target: path)
      path
    rescue Aws::S3::Errors::ServiceError => e
      raise Failure, "download failed: #{key} (#{e.class.name.split('::').last})"
    end

    def put(key, path, content_type)
      require "aws-sdk-s3"
      Aws::S3::TransferManager.new(client: client)
                              .upload_file(path, bucket: @bucket, key: key, content_type: content_type) or
        raise Failure, "upload failed: #{key}"
    end

    private

    def client
      @client ||= Aws::S3::Client.new(
        access_key_id: DigestVideo.secret(R2_ITEM, "access-key-id-#{@suffix}"),
        secret_access_key: DigestVideo.secret(R2_ITEM, "secret-access-key-#{@suffix}"),
        endpoint: DigestVideo.secret(R2_ITEM, "endpoint"),
        region: DigestVideo.secret(R2_ITEM, "region")
      )
    end
  end

  # The hub API: POST /api/v1/auth { secret } → bearer token, then the call.
  class ApiClient
    def initialize(base_url:, repo_root:)
      @base = base_url.chomp("/")
      @repo_root = repo_root
    end

    def authenticate
      @token ||= begin
        res = request(Net::HTTP::Post, "/api/v1/auth", { secret: agent_secret }, nil)
        raise Failure, "API auth #{res.code} at #{@base}" unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body).fetch("token")
      rescue JSON::ParserError, KeyError, TypeError
        raise Failure, "API auth at #{@base} answered #{res.code} but not JSON with a token"
      end
    end

    def create(payload) = post("/api/v1/music_videos", { music_video: payload })

    def show(slug) = data(request(Net::HTTP::Get, "/api/v1/music_videos/#{slug}", nil, authenticate))

    def get(path) = data(request(Net::HTTP::Get, path, nil, authenticate))

    def post(path, payload) = data(request(Net::HTTP::Post, path, payload, authenticate))

    # The data of a success; a refusal raises with the API's own code.
    def data(res)
      body = JSON.parse(res.body) rescue {}
      unless res.is_a?(Net::HTTPSuccess)
        raise Failure, "API #{res.code}: #{[body['error_code'], body['error'] || res.body.to_s[0, 200]].compact.join(' ')}"
      end

      body["data"]
    end

    private

    def request(klass, path, body, bearer)
      uri = URI.join("#{@base}/", path.delete_prefix("/"))
      req = klass.new(uri, "Content-Type" => "application/json")
      req["Authorization"] = "Bearer #{bearer}" if bearer
      req.body = JSON.generate(body) if body
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 60) do |http|
        http.request(req)
      end
    end

    def agent_secret
      env = ENV["AGENT_API_SECRET"].to_s.strip
      return env unless env.empty?

      dotenv = File.join(@repo_root, ".env")
      line = File.readable?(dotenv) && File.foreach(dotenv).find { |l| l.start_with?("AGENT_API_SECRET=") }
      value = line && line.split("=", 2).last.strip.delete("\"'")
      return value if value && !value.empty?

      DigestVideo.secret("Agent API Secret", "AGENT_API_SECRET")
    end
  end
end

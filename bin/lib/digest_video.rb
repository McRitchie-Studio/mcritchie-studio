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
  class NotBuilt < Failure; end

  H264 = "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]"
  ANY = "bv*[height<=1080]+ba/b[height<=1080]/b"
  R2_ITEM = "r2.mcritchie-studio"
  TARGETS = {
    false => { bucket: "mcritchie-studio-dev", suffix: "dev", api: "http://localhost:3000" },
    true => { bucket: "mcritchie-studio-production", suffix: "prod", api: "https://mcritchie.studio" }
  }.freeze

  module_function

  def target(production:) = TARGETS.fetch(production ? true : false)

  def platform_for(url)
    host = URI.parse(url.to_s).host.to_s.downcase.sub(/\A(?:www|m|music)\./, "")
    case host
    when "youtube.com", "youtu.be" then "youtube"
    when "tiktok.com" then raise NotBuilt, "not built yet: download-tiktok"
    when "instagram.com" then raise NotBuilt, "not built yet: download-instagram"
    else raise Failure, "unsupported host #{host.inspect}: ask Alex"
    end
  rescue URI::InvalidURIError
    raise Failure, "not a URL: #{url}"
  end

  def youtube_id(url)
    uri = URI.parse(url)
    id = URI.decode_www_form(uri.query.to_s).to_h["v"] ||
         uri.path[%r{\A/(?:shorts/|embed/|live/)?([\w-]{11})}, 1]
    id or raise Failure, "no video id in #{url}"
  end

  def shell = ->(*cmd) { out, err, status = Open3.capture3(*cmd); [out, err, status.success?] }

  # One run: download (or reuse --from-dir), make it playable, store, record.
  class Runner
    def initialize(workdir:, shell:, storage:, api:, out: $stdout, from_dir: nil, dry_run: false,
                   encoder: "libx264", ytdlp: "yt-dlp", bucket: "mcritchie-studio-dev")
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
    end

    def call(url)
      platform = DigestVideo.platform_for(url)
      id = DigestVideo.youtube_id(url)
      dir = @from_dir || File.join(@workdir, id).tap { |d| FileUtils.mkdir_p(d) }
      download(url, dir) unless @from_dir

      mp4 = playable(find(dir, id, ".mp4"))
      info = JSON.parse(File.read(find(dir, id, ".info.json")))
      vtt = Dir.glob(File.join(dir, "*#{id}*.vtt")).min
      credits = MusicVideos::CreditParser.new.parse(title: info["title"], uploader: info["uploader"],
                                                    artists: info["artists"] || info["artist"].to_s.split(", "))
      keys = MusicVideos::ObjectKeys.new(primary: credits.primary, featured: credits.featured, song: credits.song)
      payload = {
        platform: platform, source_url: info["webpage_url"] || url, source_id: id,
        title: info["title"], uploader: info["uploader"], credited_artists: Array(info["artists"]),
        duration_ms: duration_ms(mp4), source_object_key: keys.source_mp4, info_object_key: keys.info_json,
        caption_timing: MusicVideos::VttTiming.parse(vtt && File.read(vtt))
      }
      return report_dry_run(payload, mp4) if @dry_run

      store(keys, mp4, info)
      data = @api.create(payload)
      report(data, payload)
      data
    end

    private

    def download(url, dir)
      @out.puts "downloading #{url} (H.264 first)"
      common = ["--merge-output-format", "mp4", "--write-info-json", "--write-subs", "--write-auto-subs",
                "--sub-format", "vtt", "--sub-langs", "en.*,en", "-P", dir, "-o", "%(id)s.%(ext)s", url]
      _o, err, ok = @shell.call(@ytdlp, "-f", H264, *common)
      return if ok

      @out.puts "no H.264 format (#{err.to_s.lines.last&.strip}); downloading best and converting"
      _o, err, ok = @shell.call(@ytdlp, "-f", ANY, *common)
      raise Failure, "yt-dlp failed: #{err.to_s.lines.last&.strip}" unless ok
    end

    def find(dir, id, ext)
      Dir.glob(File.join(dir, "*#{id}*#{ext}")).reject { |p| p.end_with?(".h264.mp4") }.min or
        raise Failure, "no #{ext} for #{id} in #{dir}"
    end

    # QuickTime plays H.264 + AAC. Anything else (VP9, Opus) is re-encoded;
    # audio goes to AAC, never copied, since Opus in MP4 will not play.
    def playable(mp4)
      video, audio = codecs(mp4)
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

    # The description can quote lyrics, so the stored info.json drops it.
    def store(keys, mp4, info)
      @out.puts "uploading to r2://#{@bucket}/#{keys.source_mp4}"
      @storage.put(keys.source_mp4, mp4, "video/mp4")
      Tempfile.create(["info", ".json"]) do |file|
        file.write(JSON.generate(info.except("description")))
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

    def create(payload)
      res = request(Net::HTTP::Post, "/api/v1/music_videos", { music_video: payload }, token)
      body = JSON.parse(res.body) rescue {}
      raise Failure, "API #{res.code}: #{body['error'] || res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)

      body["data"]
    end

    private

    def token
      res = request(Net::HTTP::Post, "/api/v1/auth", { secret: agent_secret }, nil)
      raise Failure, "API auth #{res.code} at #{@base}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)["token"]
    end

    def request(klass, path, body, bearer)
      uri = URI.join("#{@base}/", path.delete_prefix("/"))
      req = klass.new(uri, "Content-Type" => "application/json")
      req["Authorization"] = "Bearer #{bearer}" if bearer
      req.body = JSON.generate(body)
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

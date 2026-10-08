# frozen_string_literal: true

require_relative "digest_video"

# The chat door of the tiktok-draft SOP
# (docs/agents/agents/turf_monster/sops/tiktok-draft.md): one clip, by its slug,
# into the operator's TikTok drafts, through the hub API. The server does the
# work (Tiktok::DraftClip): it holds the TikTok keys and reads the version from
# R2. This side decides nothing; it asks, prints and waits.
#
# CREATING a draft needs an admin agent session: the hub refuses the shared
# token and a studio session on that one request (Api::V1::TiktokDraftsController).
# The operator's shell holds its token in AGENT_ADMIN_SESSION_TOKEN; reading
# (a dry run, --status, --whoami) needs only the shared token every desk has.
module TiktokDraftCli
  class Failure < StandardError; end

  ADMIN_TOKEN_ENV = "AGENT_ADMIN_SESSION_TOKEN"

  # What to do about a missing, expired or refused admin session.
  ADMIN_SESSION_HOWTO = "A draft needs an admin session (Xan or Steffon). From a shell on the hub you are drafting on, " \
                        "grant one and keep its token out of sight:\n" \
                        "  local or desk hub:  export #{ADMIN_TOKEN_ENV}=\"$(bin/rails agent_sessions:grant_admin)\"\n" \
                        "  production:         export #{ADMIN_TOKEN_ENV}=\"$(heroku run --no-tty -a mcritchie-studio " \
                        "-- bin/rails agent_sessions:grant_admin 2>/dev/null)\"\n" \
                        "It lasts 8 hours. Then re-run this command in the same shell. " \
                        "The clip card's Draft to TikTok button is the other door."

  # A signed session token as Rails writes one: payload, "--", digest.
  TOKEN_LINE = %r{\A[A-Za-z0-9+/=_-]{20,}--[0-9a-f]{40,128}\z}

  # The token out of what the grant command printed. A one-off dyno folds its
  # stderr into the same stream, so the capture may carry the grant's own
  # sentence or a boot warning beside the token: take the line that is one.
  # nil when there is none.
  def self.admin_token(raw)
    raw.to_s.lines.map(&:strip).reverse.find { |line| line.match?(TOKEN_LINE) }
  end

  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

  # Is this hub on this machine? Everything else can reach a real phone.
  def self.local_hub?(base_url)
    LOCAL_HOSTS.include?(URI(base_url.to_s.strip).host.to_s.downcase)
  rescue URI::InvalidURIError
    false
  end

  # Why a draft on this hub may not go ahead without --yes, or nil when it may.
  # The hub's URL decides, not the flag that named it: --api pointed at
  # production is production.
  def self.yes_refusal(base_url:, yes:)
    return nil if yes || local_hub?(base_url)

    "a draft on #{base_url} lands on Alex's phone. Show him the --dry-run caption, then re-run with --yes on his word."
  end

  class Runner
    POLL_EVERY = 5
    # States a status read can still settle: the bytes are with TikTok.
    WITH_TIKTOK = %w[processing unknown].freeze

    # api: DigestVideo::ApiClient (get/post) on the shared token. admin_api: the
    # same hub on the admin session's token, or nil when the shell holds none;
    # only the request that creates a draft goes through it. wait: seconds to
    # wait for the attempt to settle after a draft is requested.
    def initialize(api:, admin_api: nil, out: $stdout, wait: 150, sleeper: ->(s) { sleep(s) }, clock: -> { Time.now })
      @api = api
      @admin_api = admin_api
      @out = out
      @wait = wait
      @sleeper = sleeper
      @clock = clock
    end

    # What a draft would send, and the attempts so far. Writes nothing.
    def dry_run(slug)
      data = @api.get(index_path(slug))
      print_clip(data)
      print_preview(data["preview"])
      print_attempts(data["attempts"])
      @out.puts "dry run: nothing was recorded and nothing reached TikTok."
      data
    end

    # Records an attempt, then waits for it to settle (or for `wait` to run out).
    def draft(slug)
      raise Failure, "#{ADMIN_TOKEN_ENV} is not set. #{ADMIN_SESSION_HOWTO}" unless @admin_api

      data = @api.get(index_path(slug))
      print_clip(data)
      refused = data.dig("preview", "refused")
      raise Failure, "#{slug} cannot be drafted: #{refused}" if refused
      raise Failure, "this server cannot draft: the TikTok keys are not set on it" unless data.dig("clip", "available")

      print_preview(data["preview"])
      attempt = create(slug)
      @out.puts "recorded attempt #{attempt['id']}; the server is uploading #{attempt['byte_size']} bytes."
      settle(slug, attempt["id"])
    end

    # Every attempt, with one more status read for any still processing.
    def status(slug)
      data = @api.get(index_path(slug))
      print_clip(data)
      attempts = Array(data["attempts"]).map do |a|
        WITH_TIKTOK.include?(a["state"]) ? @api.post("/api/v1/tiktok_drafts/#{a['id']}/refresh", {}) : a
      end
      print_attempts(attempts)
      attempts
    end

    # The probe: the account the server's TikTok keys post as.
    def whoami
      info = @api.get("/api/v1/tiktok/creator_info")
      @out.puts "TikTok account: @#{info['creator_username']} (#{info['creator_nickname']})"
      @out.puts "  max video length: #{info['max_video_post_duration_sec']} s" if info["max_video_post_duration_sec"]
      @out.puts "  privacy options: #{Array(info['privacy_level_options']).join(', ')}" if info["privacy_level_options"]
      info
    end

    private

    def index_path(slug) = "/api/v1/alt_video_clips/#{slug}/tiktok_drafts"

    # The one gated request. A refusal of the session itself (401 ended, 403 not
    # admin) says how to get a fresh one; any other refusal is the hub's own words.
    def create(slug)
      @admin_api.post(index_path(slug), { requested_by: "bin/tiktok-draft" })
    rescue DigestVideo::Failure => e
      raise unless e.message.match?(/\AAPI 40[13]:/)

      raise Failure, "#{e.message}\n#{ADMIN_SESSION_HOWTO}"
    end

    def settle(slug, id)
      deadline = @clock.call + @wait
      loop do
        attempt = Array(@api.get(index_path(slug))["attempts"]).find { |a| a["id"] == id }
        raise Failure, "attempt #{id} is no longer listed for #{slug}" unless attempt

        if %w[delivered failed].include?(attempt["state"]) || @clock.call >= deadline
          print_attempt(attempt)
          raise Failure, "attempt #{id} failed: #{attempt['error']}" if attempt["state"] == "failed"

          if attempt["state"] == "unknown"
            @out.puts "the upload reached TikTok but its status is unknown: look in the TikTok drafts on the phone, and " \
                      "do not draft it again until you have. `bin/tiktok-draft #{slug} --status` reads TikTok again."
          elsif attempt["state"] != "delivered"
            @out.puts "still #{attempt['state']} after #{@wait}s: run `bin/tiktok-draft #{slug} --status` to read TikTok again."
          end
          return attempt
        end
        @sleeper.call(POLL_EVERY)
      end
    end

    def print_clip(data)
      clip = data["clip"] || {}
      version = clip["primary_version"] ? "primary Version #{clip['primary_version']}" : "no primary version"
      @out.puts "#{clip['slug']} (#{clip['name']} of #{clip['alt_video']}, #{version})"
      @out.puts "  STAND-IN: this server answers for TikTok; nothing will reach it." if clip["stand_in"]
    end

    def print_preview(preview)
      return @out.puts("  cannot draft: #{preview['refused']}") if preview.nil? || preview["refused"]

      @out.puts "  athlete: #{preview['athlete']} (#{preview['look']}), #{preview['athlete_rule']}"
      @out.puts "  team: #{preview['team']}, from the #{preview['team_from']}; record #{preview.dig('facts', 'record')} " \
                "read #{preview.dig('facts', 'read_at')} from #{preview.dig('facts', 'source')}"
      Array(preview["exceptions"]).each { |note| @out.puts "  CHECK: #{note}" }
      @out.puts "caption (#{preview['caption_length']} of 2200 characters; paste it when you post):"
      @out.puts preview["caption"]
    end

    def print_attempts(attempts)
      attempts = Array(attempts)
      return @out.puts("no attempts yet") if attempts.empty?

      attempts.each { |a| print_attempt(a) }
    end

    def print_attempt(a)
      line = "attempt #{a['id']}: Version #{a['version_number']} · #{a['state_label']}"
      line += " · TikTok #{a['tiktok_status']}" if a["tiktok_status"]
      line += " · publish_id #{a['publish_id']}" if a["publish_id"]
      @out.puts line
      @out.puts "  error: #{a['error']}" if a["error"]
    end
  end
end

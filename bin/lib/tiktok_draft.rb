# frozen_string_literal: true

require_relative "digest_video"

# The chat door of the tiktok-draft SOP
# (docs/agents/agents/turf_monster/sops/tiktok-draft.md): one clip, by its slug,
# into the operator's TikTok drafts, through the hub API. The server does the
# work (Tiktok::DraftClip): it holds the TikTok keys and reads the version from
# R2. This side decides nothing; it asks, prints and waits.
module TiktokDraft
  class Failure < StandardError; end

  class Runner
    POLL_EVERY = 5

    # api: DigestVideo::ApiClient (get/post). wait: seconds to wait for the
    # attempt to settle after a draft is requested.
    def initialize(api:, out: $stdout, wait: 150, sleeper: ->(s) { sleep(s) }, clock: -> { Time.now })
      @api = api
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
      data = @api.get(index_path(slug))
      print_clip(data)
      refused = data.dig("preview", "refused")
      raise Failure, "#{slug} cannot be drafted: #{refused}" if refused
      raise Failure, "this server cannot draft: the TikTok keys are not set on it" unless data.dig("clip", "available")

      print_preview(data["preview"])
      attempt = @api.post(index_path(slug), { requested_by: "bin/tiktok-draft" })
      @out.puts "recorded attempt #{attempt['id']}; the server is uploading #{attempt['byte_size']} bytes."
      settle(slug, attempt["id"])
    end

    # Every attempt, with one more status read for any still processing.
    def status(slug)
      data = @api.get(index_path(slug))
      print_clip(data)
      attempts = Array(data["attempts"]).map do |a|
        a["state"] == "processing" ? @api.post("/api/v1/tiktok_drafts/#{a['id']}/refresh", {}) : a
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

    def settle(slug, id)
      deadline = @clock.call + @wait
      loop do
        attempt = Array(@api.get(index_path(slug))["attempts"]).find { |a| a["id"] == id }
        raise Failure, "attempt #{id} is no longer listed for #{slug}" unless attempt

        if %w[delivered failed].include?(attempt["state"]) || @clock.call >= deadline
          print_attempt(attempt)
          raise Failure, "attempt #{id} failed: #{attempt['error']}" if attempt["state"] == "failed"

          if attempt["state"] != "delivered"
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

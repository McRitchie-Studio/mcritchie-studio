# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "digest_video"
require_relative "../../lib/music_videos/object_keys"
require_relative "../../lib/music_videos/stitch_plan"
require_relative "../../lib/music_videos/stitcher"

# The agent side of the final stitch (bin/stitch-video): take the stitch an
# alt video's page asked for (or ask for one), fetch its primary versions and
# the source from R2,
# crossfade them over the source audio with ffmpeg (MusicVideos::Stitcher, the
# same code a local hub's job runs), upload the MP4 and report it through the
# API. Runs on the operator's Mac: production dynos have no ffmpeg.
module StitchVideo
  Failure = DigestVideo::Failure

  class Runner
    def initialize(api:, storage:, shell:, out: $stdout, workdir:, source: nil, dry_run: false, force: false,
                   bucket: "mcritchie-studio-dev", alt: 1)
      @api = api
      @storage = storage
      @stitcher = MusicVideos::Stitcher.new(shell:, out:)
      @out = out
      @workdir = workdir
      @source = source
      @dry_run = dry_run
      @force = force
      @bucket = bucket
      @alt = Integer(alt)
    end

    def call(slug)
      base = "/api/v1/music_videos/#{slug}/alt_videos/#{@alt}/stitches"
      board = @api.get(base)
      return dry_run(slug, board) if @dry_run

      stitch = waiting(board) || @api.post(base, {})
      if stitch["state"] == "running" && !@force
        raise Failure, "stitch #{stitch['number']} of #{label(slug)} is already running (since #{stitch['started_at']}): " \
                       "pass --force if that run is dead"
      end
      stitch = @api.post("#{base}/#{stitch['number']}/start", { force: @force })
      @out.puts "stitch #{stitch['number']} of #{label(slug)}: versions #{take_list(stitch)}"
      result = run(slug, stitch)
      done = @api.post("#{base}/#{stitch['number']}/finish", result.report)
      @out.puts format("stitch %d done: %.3f s, %dx%d at %s fps, %.1f MB, r2://%s/%s", done["number"],
                       result.duration_ms / 1000.0, result.width, result.height, result.frame_rate,
                       result.byte_size / 1_048_576.0, @bucket, done["object_key"])
      result
    end

    private

    # The stitch to run: the one waiting, or with --force one a dead run left behind.
    def waiting(board)
      newest = board["stitches"].first
      return newest if newest && (newest["state"] == "requested" || (@force && %w[running failed].include?(newest["state"])))

      nil
    end

    def run(slug, stitch)
      in_workdir(slug, stitch) { |dir| @stitcher.call(stitch, store: @storage, dir:, source: @source) }
    rescue MusicVideos::Stitcher::Failure, Failure => e
      report_failure(slug, stitch, e.message)
      raise Failure, e.message
    rescue StandardError, Interrupt => e
      report_failure(slug, stitch, "#{e.class.name}: #{e.message}")
      raise
    end

    def report_failure(slug, stitch, reason)
      @api.post("/api/v1/music_videos/#{slug}/alt_videos/#{@alt}/stitches/#{stitch['number']}/failed", { reason: })
    rescue Failure => e
      @out.puts "could not report the failure: #{e.message}"
    end

    # --dry-run: fetch and measure, print the plan; no state changes, no
    # encode, no upload.
    def dry_run(slug, board)
      stitch = waiting(board) || preview(slug, board)
      @out.puts "stitch #{stitch['number']} of #{label(slug)} (dry run: nothing started, encoded, uploaded or reported): " \
                "versions #{take_list(stitch)}"
      in_workdir(slug, stitch) { |dir| @stitcher.call(stitch, store: @storage, dir:, source: @source, dry_run: true) }
    rescue MusicVideos::Stitcher::Failure => e
      raise Failure, e.message
    end

    # What a request made now would hold, built from the API's read alone.
    def preview(slug, board)
      raise Failure, "#{label(slug)} is not ready to stitch: #{board['blocker']}" unless board["ready"]

      number = board["stitches"].map { |s| s["number"] }.max.to_i + 1
      source_key = board["source_object_key"]
      { "number" => number, "source_object_key" => source_key,
        "object_key" => MusicVideos::ObjectKeys.alt_stitched(source_key:, alt_number: @alt, number:),
        "takes" => board["current_takes"] }
    end

    # The video's own folder under the digest workdir keeps the downloads, so
    # a second stitch fetches only the takes that changed.
    def in_workdir(slug, stitch)
      dir = File.join(@workdir, "stitch", slug, "alt_#{format('%02d', @alt)}")
      FileUtils.mkdir_p(dir)
      FileUtils.rm_f(File.join(dir, File.basename(stitch["object_key"])))
      yield dir
    end

    def take_list(stitch) = stitch["takes"].map { |t| t["take"] }.join(", ")

    def label(slug) = "#{slug} alt video #{@alt}"
  end
end

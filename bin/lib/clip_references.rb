# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "digest_video"
require_relative "../../lib/music_videos/object_keys"
require_relative "../../lib/music_videos/person_letters"

# The Mac side of lettered clip references (recast pipeline, piece 16;
# bin/clip-references). For each chunk of a source it pulls 2-3 stills where
# the chunk's people are clearly on screen (from the cast's sightings), and
# draws each person's LETTER over them (Person 1 = A, Person 2 = B, ... fixed
# per source), so a Higgsfield prompt can say "Person B -> #4 Dak Prescott".
#
# Two steps, because only eyes can say where a person stands in a frame:
#
#   --extract  pulls the frames (ffmpeg, an accurate seek: -ss before -i on a
#              re-decoded frame) and writes tags.json listing, per frame, the
#              letters the sightings expect, with an empty "tags" list.
#   (agent)    looks at each frame and fills its tags: [{ letter, x, y }],
#              x and y the fraction of the width and height where the tag sits.
#              A letter is not a name; only the operator maps people to real people.
#   --apply    draws the tags (ImageMagick `magick`: this ffmpeg has no drawtext),
#              uploads each lettered JPEG to R2 under .../chunks/refs/ and posts
#              each chunk's set to POST /api/v1/music_videos/:slug/chunks/:n/references.
module ClipReferences
  Failure = DigestVideo::Failure
  TOLERANCE_MS = 1_500 # half the sighting spacing (MusicVideos::ClipCast::TOLERANCE_MS)
  EDGE_MS = 500        # keep a frame this far inside the window
  MIN_GAP_MS = 4_000   # frames of one chunk at least this far apart
  FRAMES = 3
  TAGS_VERSION = 1
  FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
  TAG_FILL = "#FFD400"

  HOW = "Look at each frame and add one tag per person you can see in it: " \
        '{"letter": "B", "x": 0.42, "y": 0.30}, x and y the fraction of the frame\'s width and height where ' \
        "the tag goes (over the person's chest, clear of the face). \"expect\" lists who the sightings put " \
        "on screen; tag who you actually see, any letter in \"people\". Letters are Person N = the Nth letter " \
        "and are NOT names. A frame left with no tags is dropped. Then run bin/clip-references <slug> --apply."

  module_function

  # Up to `count` moments inside [start_ms, end_ms] to still, chosen from the
  # cast's sightings so the chunk's people are clearly visible. focus: the
  # ordinals that matter most (an alt video's swaps); by default everyone in
  # the window. Greedy: each pick shows the most focus people not yet shown,
  # then the most clear people. Returns [{ t_ms, letters }] in time
  # order, letters = everyone sighted at that moment.
  def pick_times(performers, start_ms:, end_ms:, focus: nil, count: FRAMES)
    lo = start_ms + EDGE_MS
    hi = end_ms - EDGE_MS
    return [] if hi < lo

    sighted = performers.to_h { |p| [p["ordinal"], Array(p["sightings"])] }
    moments = sighted.values.flatten.map { |s| s["t_ms"] }.select { |t| t.between?(lo, hi) }.uniq.sort
    present = sighted.select { |_o, ss| ss.any? { |s| s["t_ms"].between?(start_ms - TOLERANCE_MS, end_ms + TOLERANCE_MS) } }.keys
    focus = (focus.nil? ? present : focus & present)
    focus = present if focus.empty?

    seen = ->(t, clear_only) { sighted.select { |_o, ss| ss.any? { |s| (s["t_ms"] - t).abs <= TOLERANCE_MS && (!clear_only || s["visibility"] == "clear") } }.keys }
    picked = []
    shown = []
    mid = (start_ms + end_ms) / 2
    while picked.size < count
      open = moments.reject { |t| picked.any? { |p| (p - t).abs < MIN_GAP_MS } }
      break if open.empty?

      # Focus people not shown yet (background people are often only partly
      # visible, so any sighting counts), then focus people clear, then anyone clear.
      best = open.max_by do |t|
        clear = seen.call(t, true)
        [(seen.call(t, false) & (focus - shown)).size, (clear & focus).size, clear.size, -(t - mid).abs]
      end
      picked << best
      shown |= seen.call(best, false) & focus
    end
    fill_evenly(picked, lo, hi, [count, 2].min)
    picked.sort.map { |t| { "t_ms" => t, "letters" => seen_at(sighted, t) } }
  end

  # With too few sightings, add moments spread over the window.
  def fill_evenly(picked, lo, hi, want)
    [0.5, 0.25, 0.75].each do |f|
      break if picked.size >= want

      t = (lo + ((hi - lo) * f)).round
      picked << t if picked.none? { |p| (p - t).abs < MIN_GAP_MS }
    end
  end

  def seen_at(sighted, t)
    sighted.select { |_o, ss| ss.any? { |s| (s["t_ms"] - t).abs <= TOLERANCE_MS } }.keys.sort
           .map { |o| MusicVideos::PersonLetters.for(o) }
  end

  # The tags of one frame as the agent filled them, checked: each a known
  # letter once, x and y inside the frame. Returns the tags; raises on a bad one.
  def check_tags(tags, known:, where:)
    raise Failure, "#{where}: tags must be a list" unless tags.is_a?(Array)

    tags.each do |tag|
      unless tag.is_a?(Hash) && (tag.keys - %w[letter x y]).empty?
        raise Failure, "#{where}: a tag is {letter, x, y}, got #{tag.inspect}"
      end
      raise Failure, "#{where}: no person #{tag['letter'].inspect} in this video" unless known.include?(tag["letter"])

      %w[x y].each do |axis|
        v = tag[axis]
        raise Failure, "#{where}: #{axis} must be a fraction from 0 to 1, got #{v.inspect}" unless v.is_a?(Numeric) && v.between?(0, 1)
      end
    end
    letters = tags.map { |t| t["letter"] }
    raise Failure, "#{where}: a letter is tagged twice" if letters.uniq.size != letters.size

    tags
  end

  # The ImageMagick command that draws the tags onto a frame of width x height.
  # Each tag is a yellow disc with a black ring and the letter in black.
  def draw_command(src, dest, tags, width:, height:, font: FONT)
    radius = [(height * 0.045).round, 14].max
    stroke = [(radius / 6.0).round, 2].max
    cmd = ["magick", src]
    cmd += ["-font", font] if font && File.exist?(font)
    tags.each do |tag|
      x = (tag["x"] * width).round.clamp(radius, width - radius)
      y = (tag["y"] * height).round.clamp(radius, height - radius)
      cmd += ["-fill", TAG_FILL, "-stroke", "black", "-strokewidth", stroke.to_s,
              "-draw", "circle #{x},#{y} #{x + radius},#{y}",
              "-fill", "black", "-stroke", "none", "-pointsize", (radius * 1.25).round.to_s, "-gravity", "center",
              "-annotate", format("%+d%+d", x - (width / 2), y - (height / 2)), tag["letter"], "-gravity", "northwest"]
    end
    cmd + ["-quality", "90", dest]
  end

  # One run of bin/clip-references.
  class Runner
    def initialize(api:, storage:, shell:, out: $stdout, workdir:, source: nil, dry_run: false,
                   bucket: "mcritchie-studio-dev", alt: nil, chunk: nil)
      @api = api
      @storage = storage
      @shell = shell
      @out = out
      @workdir = workdir
      @source = source
      @dry_run = dry_run
      @bucket = bucket
      @alt = alt
      @chunk = chunk
    end

    def dir(slug) = File.join(@workdir, "references", slug)

    def tags_path(slug) = File.join(dir(slug), "tags.json")

    # Step 1: still the frames and write tags.json for the agent to fill.
    def extract(slug)
      video = @api.show(slug)
      chunks = chunks_of(video)
      people = people_of(video)
      focus = focus_of(video)
      plan = chunks.map do |c|
        times = ClipReferences.pick_times(video["performers"] || [], start_ms: c["start_ms"], end_ms: c["end_ms"], focus:)
        frames = times.each_with_index.map do |m, i|
          { "file" => "frames/chunk_#{format('%02d', c['ordinal'])}_ref_#{format('%02d', i + 1)}.jpg",
            "t_ms" => m["t_ms"], "expect" => m["letters"], "tags" => [] }
        end
        { "ordinal" => c["ordinal"], "start_ms" => c["start_ms"], "end_ms" => c["end_ms"], "frames" => frames }
      end
      report_plan(slug, plan)
      return plan if @dry_run

      mp4 = source_mp4(video)
      FileUtils.mkdir_p(File.join(dir(slug), "frames"))
      plan.each { |c| c["frames"].each { |f| still(mp4, f["t_ms"], File.join(dir(slug), f["file"])) } }
      doc = { "version" => TAGS_VERSION, "slug" => slug, "alt" => @alt, "how" => HOW, "people" => people, "chunks" => plan }
      File.write(tags_path(slug), "#{JSON.pretty_generate(doc)}\n")
      @out.puts "wrote #{plan.sum { |c| c['frames'].size }} frames and #{tags_path(slug)}: fill each frame's tags, then --apply"
      plan
    end

    # Step 2: draw the agent's tags, upload, post each chunk's frames.
    def apply(slug)
      doc = read_tags(slug)
      video = @api.show(slug)
      known = people_of(video).map { |p| p["letter"] }
      hub = chunks_of(video).to_h { |c| [c["ordinal"], c] }
      posted = []
      doc["chunks"].each do |c|
        next if @chunk && c["ordinal"] != @chunk

        chunk = hub[c["ordinal"]]
        unless chunk && chunk.values_at("start_ms", "end_ms") == c.values_at("start_ms", "end_ms")
          raise Failure, "chunk #{c['ordinal']} is cut differently on the hub now: run --extract again"
        end

        frames = c["frames"].select { |f| f["tags"].is_a?(Array) && f["tags"].any? }
        frames.each { |f| ClipReferences.check_tags(f["tags"], known:, where: f["file"]) }
        dropped = c["frames"].size - frames.size
        @out.puts "chunk #{c['ordinal']}: #{dropped} frame(s) without tags dropped" if dropped.positive?
        next @out.puts("chunk #{c['ordinal']}: no tagged frames, left as it is") if frames.empty?

        posted << post_chunk(slug, video, chunk, frames)
      end
      posted
    end

    private

    def post_chunk(slug, video, chunk, frames)
      rows = frames.each_with_index.map do |f, i|
        src = File.join(dir(slug), f["file"])
        raise Failure, "missing #{src}: run --extract again" unless File.file?(src)

        dest = File.join(dir(slug), "lettered", File.basename(f["file"]))
        draw(src, dest, f["tags"])
        key = MusicVideos::ObjectKeys.chunk_reference(source_key: video["source_object_key"], ordinal: chunk["ordinal"],
                                                      start_ms: chunk["start_ms"], end_ms: chunk["end_ms"], number: i + 1)
        { path: dest, row: { "object_key" => key, "t_ms" => f["t_ms"], "letters" => f["tags"].map { |t| t["letter"] } } }
      end
      if @dry_run
        @out.puts "chunk #{chunk['ordinal']}: drew #{rows.size} frame(s) in #{File.join(dir(slug), 'lettered')} (dry run: nothing uploaded or posted)"
        return rows.map { |r| r[:row] }
      end

      rows.each do |r|
        @out.puts "uploading r2://#{@bucket}/#{r[:row]['object_key']}"
        @storage.put(r[:row]["object_key"], r[:path], "image/jpeg")
      end
      @api.post("/api/v1/music_videos/#{slug}/chunks/#{chunk['ordinal']}/references", { frames: rows.map { |r| r[:row] } })
      @out.puts "chunk #{chunk['ordinal']}: posted #{rows.size} lettered frame(s)"
      rows.map { |r| r[:row] }
    end

    def draw(src, dest, tags)
      FileUtils.mkdir_p(File.dirname(dest))
      out, err, ok = @shell.call("magick", "identify", "-format", "%w %h", src)
      raise Failure, "magick identify failed: #{err.to_s.lines.last&.strip}" unless ok

      width, height = out.split.map(&:to_i)
      _o, err, ok = @shell.call(*ClipReferences.draw_command(src, dest, tags, width:, height:))
      raise Failure, "magick draw failed: #{err.to_s.lines.last&.strip}" unless ok
    end

    # An accurate seek: -ss before -i seeks to the keyframe, then decodes to the exact time.
    def still(mp4, t_ms, path)
      _o, err, ok = @shell.call("ffmpeg", "-y", "-v", "error", "-ss", format("%.3f", t_ms / 1000.0), "-i", mp4,
                                "-frames:v", "1", "-q:v", "2", path)
      raise Failure, "ffmpeg still failed at #{t_ms} ms: #{err.to_s.lines.last&.strip}" unless ok
    end

    def read_tags(slug)
      path = tags_path(slug)
      raise Failure, "no #{path}: run --extract first" unless File.file?(path)

      doc = JSON.parse(File.read(path))
      raise Failure, "#{path} is for #{doc['slug']}, not #{slug}" unless doc["slug"] == slug
      raise Failure, "#{path} is tags version #{doc['version']}; this reads #{TAGS_VERSION}" unless doc["version"] == TAGS_VERSION

      doc
    rescue JSON::ParserError => e
      raise Failure, "#{path} is not JSON: #{e.message.lines.first&.strip}"
    end

    def chunks_of(video)
      chunks = video["chunks"] || []
      raise Failure, "#{video['slug']} has no chunks: tile it first (bin/find-clips --tile)" if chunks.empty?
      return chunks unless @chunk

      chunks.select { |c| c["ordinal"] == @chunk }.tap do |found|
        raise Failure, "#{video['slug']} has no chunk #{@chunk}" if found.empty?
      end
    end

    # Every person of the source with their letter, the agent's visual label,
    # and (with --alt) whether that alt video swaps them.
    def people_of(video)
      swapped = focus_of(video) || []
      (video["performers"] || []).sort_by { |p| p["ordinal"] }.map do |p|
        row = { "letter" => MusicVideos::PersonLetters.for(p["ordinal"]), "person" => p["ordinal"], "label" => p["label"] }
        @alt ? row.merge("swapped" => swapped.include?(p["ordinal"])) : row
      end
    end

    # With --alt N: the ordinals that alt video swaps.
    def focus_of(video)
      return nil unless @alt

      alt = (video["alt_videos"] || []).find { |a| a["number"] == @alt }
      raise Failure, "#{video['slug']} has no alt video #{@alt}" unless alt

      alt["swaps"].map { |s| s["performer_ordinal"] }
    end

    def report_plan(slug, plan)
      @out.puts "#{plan.sum { |c| c['frames'].size }} frames for #{slug}#{' (dry run: nothing extracted)' if @dry_run}"
      plan.each do |c|
        times = c["frames"].map { |f| "#{clock(f['t_ms'])} [#{f['expect'].join(' ')}]" }
        @out.puts format("  chunk %02d  %s-%s  %s", c["ordinal"], clock(c["start_ms"]), clock(c["end_ms"]), times.join("  "))
      end
    end

    # --source, else the digest's working folder, else the stored source from R2.
    def source_mp4(video)
      return @source if @source

      folder = File.join(@workdir, video["source_id"].to_s)
      local = Dir.glob(File.join(folder, "*#{video['source_id']}*.mp4")).max_by { |p| p.end_with?(".h264.mp4") ? 1 : 0 }
      return local if local

      FileUtils.mkdir_p(folder)
      path = File.join(folder, File.basename(video["source_object_key"]))
      @out.puts "downloading r2://#{@bucket}/#{video['source_object_key']}"
      @storage.get(video["source_object_key"], path)
    end

    def clock(ms) = format("%d:%04.1f", ms / 60_000, (ms % 60_000) / 1000.0)
  end
end

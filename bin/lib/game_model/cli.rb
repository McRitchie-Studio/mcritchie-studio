# frozen_string_literal: true

require_relative "../game_model"

module GameModel
  # bin/game-model <command> <workdir> ...: the mechanics of the
  # game-character-models SOP. One workdir per player and game; the agent writes
  # its spec.yml and its picks, and every paid step skips outputs already on disk,
  # so a re-run resumes rather than re-buys.
  class Cli
    PARALLEL = 5
    UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/128 Safari/537.36"
    HEADSHOT = "https://a.espncdn.com/i/headshots/nfl/players/full/%s.png"
    FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
    FACE_PACK_FOR_FULL = %w[front_neutral front_smile tq_left tq_right profile_right look_up].freeze
    PANEL_FACES = {
      "front_neutral" => %w[front_neutral tq_left tq_right profile_right],
      "tq_left" => %w[tq_left front_neutral profile_left look_up],
      "profile_right" => %w[profile_right tq_right front_neutral look_down],
      "look_up" => %w[look_up tq_left front_neutral profile_left],
      "front_smile" => %w[front_smile front_neutral tq_left tq_right],
      "rear" => %w[back tq_back profile_left]
    }.freeze
    SHEET_ORDER = %w[front_neutral tq_left profile_right look_up front_smile rear].freeze

    def initialize(argv, out: $stdout, shell: nil, edits: nil)
      @argv = argv.dup
      @out = out
      @shell = shell || ->(*cmd) { system(*cmd, exception: true) }
      @edits = edits
    end

    def run
      command = @argv.shift
      case command
      when "setup" then setup
      when "harvest" then harvest(*@argv)
      when "faces" then faces(@argv.fetch(0))
      when "identify" then identify(@argv.fetch(0))
      when "headwear" then headwear(@argv.fetch(0))
      when "find" then find(@argv.fetch(0), @argv.fetch(1))
      when "generate" then generate(@argv.fetch(0), @argv.fetch(1), attempts: flag("--attempts", 2).to_i)
      when "score" then score(@argv.fetch(0), @argv.fetch(1))
      when "board" then board(@argv.fetch(0), @argv.fetch(1))
      when "stitch" then stitch(@argv.fetch(0), iced: @argv.include?("--iced"))
      when "file" then file(@argv.fetch(0), production: @argv.include?("--production"), dry_run: @argv.include?("--dry-run"))
      else
        raise Failure, "unknown command #{command.inspect}; see bin/game-model --help"
      end
      0
    end

    # ── setup: the local face tools, outside any repo ──
    def setup
      FileUtils.mkdir_p(File.join(HOME, "bin"))
      faces_bin = File.join(HOME, "bin", "faces")
      @shell.call("swiftc", "-O", File.join(__dir__, "faces.swift"), "-o", faces_bin) unless File.executable?(faces_bin)
      venv = File.join(HOME, "venv")
      unless File.executable?(File.join(venv, "bin", "python"))
        @shell.call("python3", "-m", "venv", venv)
        @shell.call(File.join(venv, "bin", "pip"), "install", "-q", "insightface==1.0.1", "onnxruntime==1.19.2",
                    "opencv-python-headless==5.0.0.93", "numpy==2.0.2")
      end
      @out.puts "game-model tools ready in #{HOME}"
    end

    # ── harvest <workdir> <club-host> [--since YYYY-MM-DD] [--match REGEX] ──
    def harvest(dir, club, *_rest)
      since = flag("--since", "0000")
      match = Regexp.new(flag("--match", "."))
      skip = /roster|cheerleader|fan-photo|eats|mascot|through-the-years|trading-card/
      base = "https://#{club}/photos/"
      Hosts.check!(base)
      slugs = Gallery::INDEXES.flat_map { |i| Gallery.slugs(fetch("#{base}#{i}")) }.uniq
                      .select { |s| s.match?(match) && !s.match?(skip) }
      photos = []
      in_threads(slugs) do |slug|
        html = fetch(base + slug)
        date = Gallery.date(html).to_s
        next [] if date < since

        Gallery.photos(html).map { |p| p.merge("gallery" => slug, "date" => date) }
      end.each { |set| photos.concat(set) }
      photos.uniq! { |p| p["url"] }
      photos.each_with_index { |p, i| p["id"] = format("p%04d", i) }
      FileUtils.mkdir_p(File.join(dir, "raw"))
      in_threads(photos) { |p| download(p["url"], File.join(dir, "raw", "#{p['id']}.jpg")) }
      write_json(dir, "photos.json", photos)
      @out.puts "#{photos.size} photos from #{slugs.size} galleries into #{dir}/raw"
    end

    # ── faces <workdir>: every face of a usable size, cropped square ──
    def faces(dir)
      raws = Dir[File.join(dir, "raw", "*.jpg")].sort
      lines, status = Open3.capture2(File.join(HOME, "bin", "faces"), *raws)
      raise Failure, "the face detector failed (run bin/game-model setup)" unless status.success?

      FileUtils.mkdir_p(File.join(dir, "crops"))
      crops = []
      lines.each_line do |line|
        row = JSON.parse(line)
        row["faces"].each_with_index do |f, k|
          next if f["h"] < [110, row["h"] / 13].max

          name = "#{File.basename(row['file'], '.jpg')}_f#{k}"
          crops << { "crop" => name, "file" => row["file"], "face" => f, "box" => square(f, row["w"], row["h"]) }
        end
      end
      in_threads(crops) do |c|
        x, y, s = c["box"]
        sh("magick", c["file"], "-crop", "#{s}x#{s}+#{x}+#{y}", "+repage", "-resize", "512x512",
            File.join(dir, "crops", "#{c['crop']}.jpg"))
      end
      write_json(dir, "crops.json", crops)
      @out.puts "#{crops.size} faces cropped"
    end

    # ── identify <workdir>: ArcFace against the ESPN headshot (a verifier, never a reference) ──
    def identify(dir)
      spec = Spec.load(dir, needs: %w[name espn_id])
      headshot = File.join(dir, "headshot.jpg")
      unless File.size?(headshot)
        png = File.join(dir, "headshot.png")
        download(format(HEADSHOT, spec["espn_id"]), png)
        sh("magick", png, "-background", "white", "-flatten", headshot)
      end
      crops = Dir[File.join(dir, "crops", "*.jpg")].sort
      vectors = arcface_embed(dir, [headshot] + crops)
      centre = vectors.fetch(headshot) or raise Failure, "no face found in the headshot"
      scores = crops.to_h { |c| [File.basename(c, ".jpg"), Gate.score(vectors[c], centre)] }.compact
      matches = scores.select { |_, s| s >= IDENTITY_FLOOR }.sort_by { |_, s| -s }.to_h
      write_json(dir, "identity.json", matches)
      @out.puts "#{matches.size} of #{crops.size} faces are #{spec['name']} (>= #{IDENTITY_FLOOR})"
    end

    # ── headwear <workdir>: gpt-5 labels headwear on the identity matches only ──
    def headwear(dir)
      matches = read_json(dir, "identity.json")
      FileUtils.mkdir_p(File.join(dir, "headwear"))
      key = GameModel.openai_key
      in_threads(matches.keys) { |crop| classify(dir, crop, key) }
      labels = matches.keys.to_h { |c| [c, read_json(dir, "headwear/#{c}.json")["headwear"]] }
      bare = labels.select { |_, h| h == "none" }.keys
      File.write(File.join(dir, "bare.txt"), bare.map { |c| "crops/#{c}.jpg\n" }.join)
      montage(dir, bare.map { |c| "crops/#{c}.jpg" }, "bare.jpg", tile: "8x", geometry: "220x220+3+3")
      @out.puts "#{bare.size} bare-head faces of #{matches.size}; board: #{File.join(dir, 'bare.jpg')}"
    end

    # ── find <workdir> <gallery-regex>: locate him in the game's frames, helmet or not ──
    def find(dir, gallery)
      spec = Spec.load(dir, needs: %w[face_refs])
      photos = read_json(dir, "photos.json").select { |p| p["gallery"].match?(Regexp.new(gallery)) }
      files = photos.map { |p| File.join(dir, "raw", "#{p['id']}.jpg") }
      out = File.join(dir, "find.json")
      sh(python, File.join(__dir__, "arcface.py"), "find", out, spec.refs("face_refs").join(","), *files)
      hits = JSON.parse(File.read(out)).select { |r| r["score"] >= IDENTITY_FLOOR }.sort_by { |r| -r["score"] }
      montage(dir, hits.map { |r| r["file"] }.uniq.first(24), "find.jpg", tile: "4x", geometry: "640x+3+3")
      hits.first(24).each { |r| @out.puts format("%.2f %s h=%d", r["score"], File.basename(r["file"]), r["h"]) }
    end

    # ── generate <workdir> <stage> [--attempts N]: facepack | body | full | panels | iced_full | iced_panels ──
    def generate(dir, stage, attempts:)
      spec = Spec.load(dir)
      jobs = jobs_for(spec, dir, stage, attempts)
      edits = @edits || ImageEdits.new(api_key: GameModel.openai_key)
      failures = []
      in_threads(jobs) do |job|
        edits.generate(**job)
      rescue Failure => e
        failures << e.message
      end
      @out.puts "#{stage}: #{jobs.size - failures.size} of #{jobs.size} generated"
      failures.each { |f| @out.puts "  failed: #{f}" }
    end

    def jobs_for(spec, dir, stage, attempts)
      out = ->(name, n) { File.join(dir, "out", stage, "#{name}_#{n}") }
      iced = stage.start_with?("iced_")
      tries = (1..attempts)
      case stage
      when "facepack"
        refs = spec.refs("face_refs").first(MAX_REFS)
        Prompts::FACE_VIEWS.keys.product(tries.to_a).map do |view, n|
          { prompt: Prompts.face_view(spec, view), refs: refs, size: "1024x1024", out: out.call(view, n) }
        end
      when "body"
        builds = spec.refs("build_refs").first(5)
        refs = (spec.refs("uniform_refs").first(MAX_REFS - builds.size) + builds)
        %w[front back].product(tries.to_a).map do |view, n|
          { prompt: Prompts.body_template(spec, view, build_refs: builds.size), refs: refs, size: "1024x1536",
            out: out.call(view, n) }
        end
      when "full", "iced_full"
        builds = spec.refs("build_refs").first(5)
        games = spec.refs("game_refs").first(2)
        faces = FACE_PACK_FOR_FULL.map { |v| picked(spec, dir, "facepack", v) }
        front = faces + [picked(spec, dir, "body", "front")] + builds + games
        back = [picked(spec, dir, "facepack", "back"), picked(spec, dir, "body", "back")] + builds + games.first(1)
        tries.flat_map do |n|
          [{ prompt: Prompts.full_front(spec, faces: faces.size, builds: builds.size, games: games.size, iced: iced),
             refs: front, size: "1024x1536", out: out.call("front", n) },
           { prompt: Prompts.full_back(spec, builds: builds.size, games: [games.size, 1].min, iced: iced),
             refs: back, size: "1024x1536", out: out.call("back", n) }]
        end
      when "panels", "iced_panels"
        full = picked(spec, dir, iced ? "iced_full" : "full", "front")
        back_full = picked(spec, dir, "body", "back")
        pads = spec.refs("game_refs").last(1)
        pads = spec.refs("uniform_refs").first(1) if pads.empty?
        PANEL_FACES.keys.product(tries.to_a).map do |view, n|
          faces = PANEL_FACES[view].map { |v| picked(spec, dir, "facepack", v) }
          refs = view == "rear" ? faces + [back_full] + pads : faces + [full] + pads
          { prompt: Prompts.panel(spec, view, iced: iced), refs: refs, size: "1024x1024", out: out.call(view, n) }
        end
      else
        raise Failure, "stage must be facepack, body, full, panels, iced_full or iced_panels"
      end
    end

    # ── score <workdir> <stage>: ArcFace of each output against his own bare-head faces ──
    def score(dir, stage)
      spec = Spec.load(dir, needs: %w[face_refs])
      outs = Dir[File.join(dir, "out", stage, "*.png")].sort
      refs = spec.refs("face_refs")
      vectors = arcface_embed(dir, refs + outs)
      centre = Gate.centroid(refs.map { |r| vectors[r] })
      scores = outs.to_h { |o| [File.basename(o, ".png"), Gate.score(vectors[o], centre)&.round(3)] }
      write_json(dir, "out/#{stage}/scores.json", scores)
      low = Gate.below_floor(scores)
      shades = stage.start_with?("iced_") ? " (shades cover the eyes: judge iced faces by eye)" : ""
      scores.each { |name, s| @out.puts "#{name.ljust(20)} #{s ? format('%.2f', s) : '-'}#{low.include?(name) ? "  BELOW FLOOR#{shades}" : ''}" }
    end

    def board(dir, stage)
      files = Dir[File.join(dir, "out", stage, "*.png")].sort
      montage(dir, files, "board_#{stage}.jpg", tile: "6x", geometry: "360x+3+3")
      @out.puts File.join(dir, "board_#{stage}.jpg")
    end

    # ── stitch <workdir> [--iced] ──
    def stitch(dir, iced:)
      spec = Spec.load(dir)
      full = iced ? "iced_full" : "full"
      panels = iced ? "iced_panels" : "panels"
      fronts = [picked(spec, dir, full, "front"), picked(spec, dir, full, "back")]
      cells = SHEET_ORDER.map { |v| picked(spec, dir, panels, v) }
      work = File.join(dir, "sheet")
      FileUtils.mkdir_p(work)
      name = File.join(work, "#{Filing.slug(spec['name'])}-#{iced ? 'iced' : 'base'}.png")
      Stitch.commands(fronts: fronts, panels: cells, out: name, work: work).each { |cmd| sh(*cmd) }
      sh("magick", name, "-resize", "2400x", "-quality", "88", name.sub(/\.png\z/, "_preview.jpg"))
      @out.puts name
    end

    # ── file <workdir> [--production] [--dry-run]: R2, then the hub ──
    def file(dir, production:, dry_run:)
      spec = Spec.load(dir)
      target = DigestVideo.target(production: production)
      # Each run mints new keys, so a second run would file a second artifact.
      filed = File.join(dir, "filed#{production ? '' : '_dev'}.json")
      raise Failure, "already filed (#{filed}); delete it to file again" if File.exist?(filed) && !dry_run

      sheets =%w[base iced].filter_map do |variant|
        png = File.join(dir, "sheet", "#{Filing.slug(spec['name'])}-#{variant}.png")
        next unless File.size?(png)

        jpg = png.sub(/\.png\z/, ".jpg")
        sh("magick", png, "-quality", "92", jpg)
        key = Filing.key(spec.folder, spec["descriptor"], variant)
        { variant: variant, object_key: key, path: jpg }
      end
      raise Failure, "no stitched sheet in #{dir}/sheet; run stitch first" if sheets.empty?

      payload = Filing.payload(spec, sheets.map { |s| s.slice(:variant, :object_key) })
      if dry_run
        sheets.each { |s| @out.puts "dry run: would upload #{s[:path]} to r2://#{target[:bucket]}/#{s[:object_key]}" }
        @out.puts "dry run: would POST #{target[:api]}/api/v1/game_looks #{JSON.generate(payload)}"
        return
      end

      storage = DigestVideo::R2Storage.new(bucket: target[:bucket], suffix: target[:suffix])
      sheets.each { |s| storage.put(s[:object_key], s[:path], "image/jpeg") }
      api = DigestVideo::ApiClient.new(base_url: target[:api], repo_root: File.expand_path("../..", __dir__))
      data = api.post("/api/v1/game_looks", payload)
      write_json(dir, File.basename(filed), data)
      @out.puts "filed #{target[:api]}/people/#{data['person']}/models/#{data['look']}" \
                "#{data['iced_twin'] ? " and #{target[:api]}/people/#{data['person']}/models/#{data['iced_twin']}" : ''}"
    end

    private

    # The agent's pick for a slot, else the gate's best, else attempt 1.
    def picked(spec, dir, stage, slot)
      name = spec.pick(stage, slot)
      unless name
        scores_path = File.join(dir, "out", stage, "scores.json")
        scores = File.size?(scores_path) ? JSON.parse(File.read(scores_path)).select { |k, _| k.sub(/_\d+\z/, "") == slot } : {}
        name = Gate.best(scores).dig(slot, 0) || "#{slot}_1"
      end
      path = File.join(dir, "out", stage, "#{name}.png")
      raise Failure, "#{stage}/#{name}.png is missing; generate #{stage} first" unless File.size?(path)

      path
    end

    def classify(dir, crop, key)
      path = File.join(dir, "headwear", "#{crop}.json")
      return if File.size?(path)

      image = "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(File.join(dir, 'crops', "#{crop}.jpg")))}"
      schema = { type: "object", additionalProperties: false, required: %w[headwear sharp],
                 properties: { headwear: { type: "string", enum: %w[none helmet helmet_raised cap beanie headband hood other] },
                               sharp: { type: "boolean" } } }
      body = { model: CLASSIFIER_MODEL, reasoning: { effort: "low" },
               text: { format: { type: "json_schema", name: "headwear", strict: true, schema: schema } },
               input: [{ role: "user", content: [{ type: "input_image", image_url: image },
                                                 { type: "input_text", text: "What is on this man's head (helmet_raised = helmet pushed up off the face), and is his face in sharp focus?" }] }] }
      uri = URI("https://api.openai.com/v1/responses")
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{key}")
      req.body = JSON.generate(body)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 300) { |h| h.request(req) }
      raise Failure, "headwear #{crop}: HTTP #{res.code}" unless res.code == "200"

      payload = JSON.parse(res.body)
      text = payload["output"].find { |o| o["type"] == "message" }["content"].find { |c| c["type"] == "output_text" }["text"]
      File.write(path, JSON.generate(JSON.parse(text).merge("usage" => payload["usage"])))
    end

    def arcface_embed(dir, files)
      out = File.join(dir, "embed-#{SecureRandom.hex(3)}.json")
      sh(python, File.join(__dir__, "arcface.py"), "embed", out, *files)
      JSON.parse(File.read(out)).tap { File.delete(out) }
    end

    def python = File.join(HOME, "venv", "bin", "python")

    def square(face, width, height)
      s = [(face["h"] * 2.2).to_i, width, height].min
      cx = face["x"] + (face["w"] / 2)
      cy = face["y"] + (face["h"] / 2) - (face["h"] * 0.15).to_i
      [(cx - (s / 2)).clamp(0, width - s), (cy - (s / 2)).clamp(0, height - s), s]
    end

    def montage(dir, files, name, tile:, geometry:)
      return if files.empty?

      sh("magick", "montage", "-font", FONT, "-pointsize", "18", "-label", "%t",
          *files.map { |f| File.expand_path(f, dir) }, "-tile", tile, "-geometry", geometry, File.join(dir, name))
    end

    def fetch(url)
      Hosts.check!(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) do |h|
        h.request(Net::HTTP::Get.new(uri, "User-Agent" => UA))
      end
      res.is_a?(Net::HTTPSuccess) ? res.body.to_s : ""
    end

    def download(url, path)
      return if File.size?(path)

      body = fetch(url)
      File.binwrite(path, body) unless body.empty?
    end

    def in_threads(items, &block)
      queue = Queue.new
      items.each { |i| queue << i }
      results = []
      lock = Mutex.new
      Array.new([PARALLEL, items.size].min) {
        Thread.new do
          while (item = (queue.pop(true) rescue nil))
            value = block.call(item)
            lock.synchronize { results << value }
          end
        end
      }.each(&:join)
      results
    end

    def sh(*cmd) = @shell.call(*cmd)

    def flag(name, default)
      i = @argv.index(name)
      i ? @argv[i + 1] : default
    end

    def write_json(dir, name, data)
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data))
    end

    def read_json(dir, name) = JSON.parse(File.read(File.join(dir, name)))
  end
end

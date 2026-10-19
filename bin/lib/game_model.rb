# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "uri"
require "yaml"
require_relative "digest_video"

# A GAME CHARACTER MODEL: one player as he looked in one game, built in layers
# and filed as a character sheet on a look (docs: the game-character-models SOP,
# docs/agents/agents/turf_monster/sops/game-character-models.md).
#
# WHY LAYERS. One call for a whole ten-panel sheet laid the grid out wrong 14
# times in 14 (2026-10-18). Built in layers it held: (1) a FACE PACK, ten studio
# views of the bare head from the player's own bare-head photographs; (2) a
# numberless BODY TEMPLATE in the game's uniform; (3) two full bodies and six head
# panels with his specifics; then a local stitch into the 5x2 grid. Three players
# (Nix, Darnold, Williams) were built by hand this way and passed the operator's eye.
#
# WHERE IT RUNS. On the operator's Mac: the face gate is local by his ruling, and
# the face detector is Apple Vision. Production only files the result
# (POST /api/v1/game_looks), the way bin/clip-references files its frames.
module GameModel
  class Failure < StandardError; end

  # PINNED, never the rolling alias. The app's default image model scored 0.44 on
  # a 1:1 replication of a held-out photo; this snapshot scored 0.73-0.76.
  MODEL = "gpt-image-2.5-sunburst-2026-09-08"
  EDITS_URL = "https://api.openai.com/v1/images/edits"
  CLASSIFIER_MODEL = "gpt-5-2025-08-07"
  # /v1/images/edits takes at most 16 `image[]` parts.
  MAX_REFS = 16
  # A generated face under this has always looked wrong to the operator; above it
  # the score does not rank, so the eye picks among passing attempts.
  FACE_FLOOR = 0.70
  # A real photo of the player scores >= 0.39 against his headshot, other men <= 0.31.
  IDENTITY_FLOOR = 0.35
  KEY_PREFIX = "character-sheets/game-models/"
  OPENAI_ITEM = ["studio-applications", "openai.studio.applications", "credential"].freeze
  HOME = File.expand_path(ENV.fetch("GAME_MODEL_HOME", "~/.game-model"))

  # ── SOURCES: team and league media only (the operator's option B, 2026-10-17) ──
  module Hosts
    TEAM_DOMAINS = %w[
      azcardinals.com atlantafalcons.com baltimoreravens.com buffalobills.com panthers.com chicagobears.com
      bengals.com clevelandbrowns.com dallascowboys.com denverbroncos.com detroitlions.com packers.com
      houstontexans.com colts.com jaguars.com chiefs.com raiders.com chargers.com therams.com
      miamidolphins.com vikings.com patriots.com neworleanssaints.com giants.com newyorkjets.com
      philadelphiaeagles.com steelers.com 49ers.com seahawks.com buccaneers.com tennesseetitans.com
      commanders.com
    ].freeze
    LEAGUE_DOMAINS = %w[nfl.com espncdn.com].freeze
    # Wire and agency photography is out of scope, and named so a refusal says why.
    WIRE_DOMAINS = %w[gettyimages.com apnews.com ap.org reuters.com usatoday.com imagn.com imagn.photos].freeze

    def self.host(url)
      URI.parse(url.to_s).host.to_s.downcase
    rescue URI::InvalidURIError
      ""
    end

    def self.under?(host, domain) = host == domain || host.end_with?(".#{domain}")

    def self.wire?(url) = WIRE_DOMAINS.any? { |d| under?(host(url), d) }

    def self.allowed?(url)
      h = host(url)
      return false if h.empty? || wire?(url) || !url.to_s.start_with?("https://")

      (TEAM_DOMAINS + LEAGUE_DOMAINS).any? { |d| under?(h, d) }
    end

    def self.check!(url)
      return url if allowed?(url)

      why = wire?(url) ? "wire/agency photography is out of scope" : "not a team or league host"
      raise Failure, "refused #{url}: #{why} (sourcing rule: team and league media only)"
    end
  end

  # ── A CLUB SITE'S PHOTO GALLERIES (<club>.com/photos/<slug>) ──
  module Gallery
    IMG = %r{<img alt="([^"]*)"[^>]*data-src="(https://static\.clubs\.nfl\.com/image/upload/[^"]+)"}
    SLUG = %r{href="/photos/([a-z0-9-]+)"}
    INDEXES = ["", "all", "gameday", "practice"].freeze

    # Every photo on one gallery page, in page order, at the 2x rendition.
    def self.photos(html)
      html.to_s.scan(IMG).map { |alt, url|
        { "alt" => unescape(alt), "url" => url.sub(%r{/t_new_photo_album[^/]*/}, "/t_new_photo_album_2x/").sub("/t_lazy", "") }
      }.uniq { |p| p["url"] }
    end

    def self.slugs(html) = html.to_s.scan(SLUG).flatten.uniq - INDEXES

    def self.date(html) = html.to_s[/"datePublished":"(\d{4}-\d{2}-\d{2})/, 1]

    def self.unescape(text) = text.gsub("&amp;", "&").gsub("&quot;", '"').gsub("&#39;", "'").gsub("&#x27;", "'")
  end

  # ── THE PER-LOOK SPEC the agent writes after looking at the game's frames ──
  #
  # The judgment stays with the agent (what the uniform is, the facial hair that
  # week, which frames are build references); the CLI does the mechanics.
  class Spec
    # `espn_id` names an athlete; someone with no athlete record (a head coach)
    # is named by `person: { first_name, last_name, vocation }` instead, and
    # FileGameLook finds or creates him. One of the two is required to file.
    REQUIRED = %w[name descriptor number uniform jersey_panel specifics_front specifics_back
                  back_panel hair facial_hair build face_refs uniform_refs].freeze
    LISTS = %w[face_refs uniform_refs build_refs game_refs].freeze

    attr_reader :dir, :data

    # The early steps need only who he is: identify reads name and espn_id
    # before the agent has looked at a frame; generating needs the whole spec.
    def self.load(dir, needs: REQUIRED)
      path = File.join(dir, "spec.yml")
      raise Failure, "#{path} not found; write the spec first (see the SOP)" unless File.file?(path)

      new(dir, YAML.safe_load(File.read(path)) || {}, needs: needs)
    end

    def initialize(dir, data, needs: REQUIRED)
      @dir = dir
      @data = data
      missing = needs.reject { |k| data[k].to_s.strip != "" && data[k] != [] }
      raise Failure, "spec.yml is missing #{missing.join(', ')}" if missing.any?
    end

    def [](key) = @data[key]

    def refs(key) = Array(@data[key]).map { |p| File.expand_path(p, @dir) }

    def picks = @data["picks"] || {}

    # The pick for a slot, else nil (the gate's best then stands).
    def pick(stage, slot) = (picks[stage] || {})[slot]

    # The R2 folder this subject files under: his espn_id, else his name slug
    # (the hub refuses a key filed under any other folder).
    def folder
      return @data["espn_id"].to_s if @data["espn_id"].to_s != ""

      person = @data["person"] || {}
      raise Failure, "spec.yml names nobody: give espn_id, or person: { first_name, last_name, vocation }" if person.empty?

      Filing.slug("#{person['first_name']} #{person['last_name']}")
    end
  end

  # ── THE PROMPTS, each one proven on the hand-built sheets ──
  module Prompts
    FACE_VIEWS = {
      "front_neutral" => "facing the camera straight on, head level, relaxed neutral expression, mouth closed",
      "front_smile" => "facing the camera straight on, head level, a natural broad smile showing his upper teeth",
      "tq_left" => "head turned three-quarters to HIS RIGHT (face pointing to the left side of the frame), neutral expression",
      "tq_right" => "head turned three-quarters to HIS LEFT (face pointing to the right side of the frame), neutral expression",
      "profile_left" => "in exact profile facing the LEFT side of the frame, neutral expression, ear fully visible",
      "profile_right" => "in exact profile facing the RIGHT side of the frame, neutral expression, ear fully visible",
      "look_up" => "face three-quarters to the left, chin raised, looking upward, neutral expression",
      "look_down" => "face three-quarters to the right, chin lowered, looking down, neutral expression",
      "back" => "seen directly from BEHIND, showing the back of his head, his hair from the crown down to the nape, " \
                "and the backs of his ears; no face visible",
      "tq_back" => "seen from behind and to the side (three-quarter rear view), back of head and the edge of his " \
                   "jaw and ear visible, face turned away"
    }.freeze

    # "three-quarters toward the LEFT" came out facing right 0 times in 4 right;
    # naming where the nose, the back of the head and the visible ear point went 3 for 3.
    TQ_LEFT = "in a THREE-QUARTER view facing the LEFT EDGE of the image, exactly like the FIRST image: in the " \
              "picture his nose and eyes point toward the left edge, the back of his head is toward the right " \
              "edge, and his LEFT ear is the ear the camera sees; his shoulders are turned the same way, neutral expression"

    PANEL_VIEWS = {
      "front_neutral" => "facing the camera straight on, head level, relaxed neutral expression",
      "tq_left" => TQ_LEFT,
      "profile_right" => "head in exact profile facing the RIGHT side of the frame, neutral expression, ear fully visible",
      "look_up" => "face three-quarters to the left, chin raised, looking upward",
      "front_smile" => "facing the camera straight on, a natural broad smile",
      "rear" => "seen directly from BEHIND: the back of his head and his hair from crown to nape, no face visible"
    }.freeze

    # THE ICED TWIN'S WORDING IS Appearances::CharacterSheetPrompt's, copied because
    # this CLI does not boot Rails; test/services/appearances/game_model_iced_parity_test.rb pins the copy.
    SHADES = "one specific pair of designer sunglasses - black acetate frames, dark tinted lenses, " \
             "thin gold metal temples - worn over his eyes"
    ICED_PIECES = [
      "chain: a heavy diamond-encrusted Cuban link chain with a large diamond pendant, worn OVER the jersey",
      "watch on his LEFT wrist: a fully diamond-encrusted watch (iced-out bezel, dial and bracelet)",
      "bracelet on his RIGHT wrist (the hand without the watch): a diamond tennis bracelet",
      "grill: a diamond-encrusted grill covering his top and bottom teeth",
      "rings: diamond-encrusted rings on several fingers of both hands"
    ].freeze
    RINGS_VIEW = "RINGS SHOT: facing the camera, both hands raised in front of his chest with the backs of " \
                 "his fingers turned to the lens so every ring is large, sharp and clearly readable"
    GRILL_VIEW = "GRILL SHOT: front, a big wide open smile showing the diamond-encrusted grill on his teeth"
    ICED_PANEL_VIEWS = PANEL_VIEWS.merge("look_up" => RINGS_VIEW, "front_smile" => GRILL_VIEW).freeze

    PADS = "It is worn over hard SHOULDER PADS: the shoulder line is squared, rigid and clearly wider than his " \
           "chest, with both shoulders fully inside the frame."
    BACKDROP = "Plain neutral mid-grey seamless background, soft even studio lighting"
    PROPORTIONS = "Natural human proportions: the body is about seven and a half heads tall; his elbows sit at his " \
                  "waistline, his wrists at the level of his hips, and his fingertips reach only the upper-middle " \
                  "of his thighs - the arms must NOT look long. His shoulders, in hard shoulder pads, are the widest " \
                  "part of him, clearly wider than his hips."

    module_function

    def identity(spec)
      "his face, bone structure, skin tone and texture, eyes, nose, ears, hairline, his hair (#{spec['hair']}), " \
        "and his facial hair (#{spec['facial_hair']}) must match them exactly"
    end

    def iced_clause
      "ICED-OUT LOOK. He also wears #{SHADES}, and this exact jewelry set: " \
        "#{ICED_PIECES.join('; ')}. CONSISTENCY: the sunglasses and every piece of jewelry are ONE fixed set - " \
        "identical design, size, colour and position wherever they are visible."
    end

    def face_view(spec, view)
      "The photographs above all show the same real man, bare-headed, in many different settings. Create a clean " \
        "IDENTITY REFERENCE photograph of this exact man for a face model: #{identity(spec)}, including the natural " \
        "lines and texture of his skin. His hair is DRY. Head and shoulders only, #{FACE_VIEWS.fetch(view)}. He " \
        "wears a plain dark navy crew-neck t-shirt with no logo. #{BACKDROP} with no harsh shadows and no colour " \
        "cast. Sharp focus, natural skin, photorealistic, square framing, the head filling most of the frame."
    end

    def body_template(spec, view, build_refs:)
      pose = view == "back" ? "standing with his back to the camera, seen directly from behind, arms relaxed at his sides" :
                              "standing facing the camera straight on, arms relaxed at his sides"
      builds = build_refs ? " The LAST #{build_refs} images are BUILD photographs of one player in other outfits: " \
                            "copy his body and proportions from them, not their outfits." : ""
      "The photographs above show the uniform as it was worn in one game.#{builds} Create a full-body studio " \
        "reference photograph of a football player wearing EXACTLY this uniform in full game gear, #{pose}. " \
        "#{spec['uniform']} He wears hard SHOULDER PADS under the jersey, exactly as in the in-game photographs: " \
        "the jersey is stretched tight over a flat, rigid plateau that sits ABOVE and BEYOND his natural shoulders. " \
        "This is a GENERIC template for any player: the jersey carries NO numbers, NO name and NO patches anywhere. " \
        "The helmet is on and his face is in shadow behind the facemask, not identifiable. No towel, no gloves. " \
        "Build: #{spec['build']}. #{PROPORTIONS} The jersey is tucked in at his natural waist. #{BACKDROP}, the " \
        "entire figure from helmet to cleats in frame with a margin above and below, photorealistic, sharp focus."
    end

    def full_front(spec, faces:, builds:, games:, iced: false)
      "The first #{faces} images are a FACE MODEL: studio views of one real man. #{identity(spec).sub(/\Ahis/, 'His')}. " \
        "The next image is a UNIFORM TEMPLATE: copy its uniform, pants, socks and cleats, but NOT its body build." \
        "#{builds.positive? ? " The next #{builds} images are BUILD photographs of this same man: copy his BODY and PROPORTIONS from them exactly, ignoring their facial hair, outfits and poses." : ''}" \
        "#{games.positive? ? " The last #{games} images are real photographs of him in this game: copy his game details from them." : ''}\n\n" \
        "Create one full-body studio reference photograph of this man standing facing the camera straight on, relaxed " \
        "and upright, arms hanging naturally at his sides with EMPTY hands, feet about hip-width apart, NO helmet - " \
        "bare head. #{PROPORTIONS} He wears the template's uniform with these details: #{spec['specifics_front']}. " \
        "#{iced ? "#{iced_clause} " : ''}Build: #{spec['build']}. #{BACKDROP}, the whole figure from the top of his " \
        "hair to his cleats in frame with a margin, photorealistic, sharp focus on his face."
    end

    def full_back(spec, builds:, games:, iced: false)
      "The FIRST image is a FACE MODEL view of the back of one real man's head. The SECOND image is a UNIFORM " \
        "TEMPLATE seen from behind: copy its uniform, helmet, pants, socks and cleats, but NOT its body build." \
        "#{builds.positive? ? " The next #{builds} images are BUILD photographs of this same man: copy his BODY and PROPORTIONS from them exactly, ignoring their outfits." : ''}" \
        "#{games.positive? ? ' The last image is a real photograph from this game showing the jersey style.' : ''}\n\n" \
        "Create one full-body studio reference photograph of this man standing with his back to the camera, wearing " \
        "his helmet, his head facing AWAY from the camera in the same direction as his body - straight ahead, NOT " \
        "looking over his shoulder; the facemask is not visible. Arms hang naturally at his sides, feet about " \
        "hip-width apart. #{PROPORTIONS} He wears the template's uniform with: #{spec['specifics_back']}. " \
        "#{iced ? "#{iced_clause} " : ''}Build: #{spec['build']}. #{BACKDROP}, the whole figure from helmet to " \
        "cleats in frame with a margin, photorealistic, sharp focus."
    end

    def panel(spec, view, iced: false)
      views = iced ? ICED_PANEL_VIEWS : PANEL_VIEWS
      jersey = view == "rear" ? "#{spec['jersey_panel']}, seen from the back: #{spec['back_panel']}" : spec["jersey_panel"]
      "The FIRST image shows exactly the head pose and expression to reproduce, and together with the other studio " \
        "face images it is the FACE MODEL of one real man: #{identity(spec)}. The full-body image shows his game " \
        "uniform; the last image is a real close-up of that uniform worn over shoulder pads.\n\n" \
        "Create a head-and-upper-torso studio reference photograph of this man, #{views.fetch(view)}, BARE HEAD with " \
        "no helmet, wearing his game uniform exactly as in the full-body image: #{jersey}. #{PADS} " \
        "#{iced ? "#{iced_clause} " : ''}Frame from just above the top of his hair down to mid-chest. #{BACKDROP} " \
        "matching the face model, photorealistic, sharp focus."
    end
  end

  # ── ONE /v1/images/edits CALL, pinned model, refs sent in the order given ──
  class ImageEdits
    def initialize(api_key:, http: Net::HTTP)
      @api_key = api_key
      @http = http
    end

    def self.multipart(boundary, prompt:, refs:, size:)
      raise Failure, "#{refs.size} reference images; /v1/images/edits takes at most #{MAX_REFS}" if refs.size > MAX_REFS
      raise Failure, "no reference images" if refs.empty?

      parts = { "model" => MODEL, "prompt" => prompt, "size" => size, "quality" => "high" }.map { |name, value|
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
      }
      refs.each do |path|
        type = File.extname(path).casecmp?(".png") ? "image/png" : "image/jpeg"
        parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"#{File.basename(path)}\"" \
                 "\r\nContent-Type: #{type}\r\n\r\n#{File.binread(path)}\r\n"
      end
      parts << "--#{boundary}--\r\n"
      parts.map { |s| s.dup.force_encoding("BINARY") }.join
    end

    # Writes <out>.png and <out>.json (usage, seconds). Skips a finished output.
    def generate(prompt:, refs:, size:, out:)
      return out if File.size?("#{out}.png")

      boundary = "----gm#{SecureRandom.hex(8)}"
      uri = URI(EDITS_URL)
      req = Net::HTTP::Post.new(uri, "Content-Type" => "multipart/form-data; boundary=#{boundary}",
                                     "Authorization" => "Bearer #{@api_key}")
      req.body = self.class.multipart(boundary, prompt: prompt, refs: refs, size: size)
      started = Time.now
      res = @http.start(uri.host, uri.port, use_ssl: true, read_timeout: 600, open_timeout: 15) { |h| h.request(req) }
      body = JSON.parse(res.body) rescue {}
      raise Failure, "#{File.basename(out)}: HTTP #{res.code} #{body.dig('error', 'message')}" unless res.code == "200"

      image = body.dig("data", 0, "b64_json") or raise Failure, "#{File.basename(out)}: no image returned"
      FileUtils.mkdir_p(File.dirname(out))
      File.binwrite("#{out}.png", Base64.decode64(image))
      File.write("#{out}.json", JSON.generate(model: MODEL, usage: body["usage"], refs: refs.map { |r| File.basename(r) },
                                              seconds: (Time.now - started).round(1), prompt: prompt))
      out
    end
  end

  # ── THE FACE GATE: highest ArcFace score per slot, flagged under the floor ──
  module Gate
    module_function

    def centroid(vectors)
      live = vectors.compact
      raise Failure, "no reference face could be embedded" if live.empty?

      mean = Array.new(live.first.size) { |i| live.sum { |v| v[i] } / live.size }
      norm = Math.sqrt(mean.sum { |x| x * x })
      mean.map { |x| x / norm }
    end

    def score(vector, centre) = vector && vector.zip(centre).sum { |a, b| a * b }

    # { "front_neutral" => ["front_neutral_1", 0.81], ... } from {"front_neutral_1" => 0.81, ...}
    def best(scores)
      scores.group_by { |name, _| name.sub(/_\d+\z/, "") }
            .transform_values { |rows| rows.max_by { |_, s| s || -1 } }
    end

    # Back views show no face to score, so the floor never applies to them.
    BACK_VIEWS = %w[back tq_back rear].freeze

    def back_view?(name) = BACK_VIEWS.include?(name.sub(/_\d+\z/, ""))

    def below_floor(scores) = scores.select { |name, s| s && s < FACE_FLOOR && !back_view?(name) }.keys.sort
  end

  # ── THE 5x2 GRID, stitched locally (the one-call grid failed 14 of 14) ──
  module Stitch
    GAP = 8
    BACKGROUND = "#808286"

    module_function

    # Two full bodies on the left; six 796px panels, three over three, on the right.
    # The halves are named after the sheet, so a base and an iced stitch never
    # share a temp file.
    def commands(fronts:, panels:, out:, work:)
      raise Failure, "a sheet needs 2 full bodies and 6 panels" unless fronts.size == 2 && panels.size == 6

      stem = File.basename(out, ".*")
      left = File.join(work, "#{stem}-left.png")
      right = File.join(work, "#{stem}-right.png")
      row = ->(set) { ["("] + set + ["-resize", "796x796", "-background", BACKGROUND, "-splice", "#{GAP}x0", "+append", "-chop", "#{GAP}x0", ")"] }
      [
        ["magick", "(", fronts[0], "-resize", "x1600", ")", "(", fronts[1], "-resize", "x1600", ")",
         "-background", BACKGROUND, "-splice", "#{GAP}x0", "+append", "-chop", "#{GAP}x0", left],
        ["magick", *row.call(panels[0, 3]), *row.call(panels[3, 3]), "-background", BACKGROUND, "-splice", "0x#{GAP}",
         "-append", "-chop", "0x#{GAP}", "-resize", "x1600", right],
        ["magick", left, right, "-background", BACKGROUND, "-splice", "#{GAP}x0", "+append", "-chop", "#{GAP}x0",
         "-bordercolor", BACKGROUND, "-border", "16", out]
      ]
    end
  end

  # ── FILING: R2, then POST /api/v1/game_looks ──
  module Filing
    module_function

    def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

    def key(folder, descriptor, variant, clock: Time)
      "#{KEY_PREFIX}#{folder}/#{slug(descriptor)}-#{variant}-#{clock.now.utc.strftime('%Y%m%d%H%M%S')}.jpg"
    end

    def payload(spec, sheets)
      who = spec["espn_id"].to_s != "" ? { espn_id: spec["espn_id"].to_s } : { person: spec["person"], team_slug: spec["team_slug"] }
      { **who, descriptor: spec["descriptor"], jersey_number: spec["number"]&.to_i,
        generation_notes: spec["notes"], sheets: sheets }.compact
    end
  end

  # OPENAI_API_KEY, else bin/secret <vault> <item> <field>: the hub's 1Password
  # door, a named reference whose value is never printed.
  def self.openai_key
    env = ENV["OPENAI_API_KEY"].to_s.strip
    return env unless env.empty?

    out, status = Open3.capture2(File.expand_path("../secret", __dir__), *OPENAI_ITEM)
    raise Failure, "could not read the OpenAI credential (#{OPENAI_ITEM.join(' ')})" unless status.success? && !out.strip.empty?

    out.strip
  end
end

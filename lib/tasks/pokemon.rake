# Pokémon reference-data provisioning. Two one-time tasks, run during a rebuild —
# NOT at seed time. The seed (db/seeds/56_pokemon.rb) is DB-only: it reads the
# committed JSON this writes. Mirrors the headshot pattern in
# db/seeds/32_headshot_links.rb (identity/URLs seeded; image bytes uploaded here).
#
#   rake pokemon:fetch           → pull Gen 1–2 (dex 1–251) from PokéAPI into the JSON
#   rake pokemon:upload_images   → mirror each Pokémon's avatars + sprites into S3
#   rake pokemon:crop_and_upload → trim each avatar's transparent margin and
#                                  upload the crop to <dex>-<slug>-cropped.png
#                                  (ADDITIVE — the original <dex>-<slug>.png is the
#                                  backup and is never overwritten or deleted)
#
# Both image tasks cover the normal AND shiny art (shiny keys carry a -shiny
# infix); VARIANTS=shiny (or normal) narrows a run to one side. All three tasks
# accept RANGE=<from>-<to> (e.g. RANGE=152-251) to work one dex slice — fetch
# merges the slice into the existing JSON, so a Johto-only run never rewrites
# (or churns) the committed Kanto rows.
require "net/http"
require "json"
require "fileutils"

namespace :pokemon do
  POKEAPI = "https://pokeapi.co/api/v2"
  DEX_RANGE = (1..251)
  # Which generation each dex slice belongs to — written onto every fetched row.
  GENERATION_RANGES = { 1 => (1..151), 2 => (152..251) }.freeze
  DATA_FILE = Rails.root.join("db/seeds/data/pokemon.json")
  # Deterministic-by-dex sources on the PokéAPI sprite CDN.
  SPRITE_CDN = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon".freeze
  # Final home — the existing S3 bucket, under a pokemon/ prefix. PATH-STYLE
  # (bucket in the path) on purpose: the virtual-hosted host
  # `mcritchie-studio-production.s3…` trips Chrome's lookalike-domain warning
  # (resembles mcritchie.studio); the generic `s3…amazonaws.com` host does not.
  S3_BASE = "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon".freeze

  # The handful of Pokémon whose display name isn't just the title-cased slug.
  DISPLAY_NAMES = {
    "nidoran-f" => "Nidoran♀",
    "nidoran-m" => "Nidoran♂",
    "mr-mime"   => "Mr. Mime",
    "farfetchd" => "Farfetch'd",
    "ho-oh"     => "Ho-Oh"
  }.freeze

  desc "Seed/refresh the Pokémon rows + cache their primary types (idempotent; safe on QA/prod)"
  task seed: :environment do
    load Rails.root.join("db/seeds/56_pokemon.rb").to_s
    # Cache the identifying (least-common) type onto primary_type. Needs the
    # pokemon_type enumerals (ranks) — a no-op until those are seeded (they are
    # persistent on QA/prod via enumerals:seed), so reads fall back to live ranking.
    updated = Pokemon.assign_primary_types!
    puts "  primary_type: #{updated} updated (#{Pokemon.where.not(primary_type: nil).count}/#{Pokemon.count} cached)"
  end

  desc "Assign a mascot to every task lacking one (idempotent; safe to re-run on prod/QA)"
  task backfill_mascots: :environment do
    count = Task.backfill_mascots!
    puts "backfilled #{count} mascot(s)"
  end

  desc "Re-derive mascots under the per-SESSION rule — every live task in a session shares its Pokémon (idempotent)"
  task resync_mascots: :environment do
    count = Task.resync_session_mascots!
    puts "re-stamped #{count} task mascot(s) by session"
  end

  desc "Pull Gen 1–2 (dex 1–251) from PokéAPI into db/seeds/data/pokemon.json (RANGE=152-251 fetches one slice, merged into the existing file)"
  task fetch: :environment do
    range = dex_range
    existing = File.exist?(DATA_FILE) ? JSON.parse(File.read(DATA_FILE)) : []
    fetched = range.map do |dex|
      data = get_json("#{POKEAPI}/pokemon/#{dex}")
      slug = data.fetch("name")
      stats = data.fetch("stats").to_h { |s| [s.dig("stat", "name"), s.fetch("base_stat")] }
      row = {
        "dex" => dex,
        "name" => DISPLAY_NAMES.fetch(slug, slug.tr("-", " ").split.map(&:capitalize).join(" ")),
        "slug" => slug,
        "types" => data.fetch("types").sort_by { |t| t.fetch("slot") }.map { |t| t.dig("type", "name") },
        "hp" => stats["hp"],
        "attack" => stats["attack"],
        "defense" => stats["defense"],
        "special_attack" => stats["special-attack"],
        "special_defense" => stats["special-defense"],
        "speed" => stats["speed"],
        "generation" => generation_for(dex),
        # Primary = the tightly-cropped avatar (rake pokemon:crop_and_upload);
        # fallback = the original uncropped official-artwork (rake pokemon:upload_images).
        "avatar_url" => "#{S3_BASE}/#{dex}-#{slug}-cropped.png",
        "avatar_fallback_url" => "#{S3_BASE}/#{dex}-#{slug}.png",
        "sprite_url" => "#{S3_BASE}/#{dex}-#{slug}-sprite.png",
        # The shiny mirror of the same three — worn when a mascot DRAW rolls
        # shiny (Pokemon.roll_shiny?), provisioned by the same two rakes.
        "shiny_avatar_url" => "#{S3_BASE}/#{dex}-#{slug}-shiny-cropped.png",
        "shiny_avatar_fallback_url" => "#{S3_BASE}/#{dex}-#{slug}-shiny.png",
        "shiny_sprite_url" => "#{S3_BASE}/#{dex}-#{slug}-shiny-sprite.png"
      }
      warn "fetched ##{format('%03d', dex)} #{row['name']}"
      row
    end
    # Merge the fetched slice into the file: rows outside the slice keep their
    # fetched fields verbatim, so a RANGE=152-251 run cannot churn the committed
    # Kanto rows. Family fields are then (re)derived across the WHOLE set —
    # they are cross-row facts (Johto gave Onix an evolution), not per-row ones.
    rows = (existing.reject { |row| range.cover?(row["dex"]) } + fetched).sort_by { |row| row["dex"] }
    stamp_family_fields(rows)
    File.write(DATA_FILE, "#{JSON.pretty_generate(rows)}\n")
    puts "wrote #{rows.size} Pokémon (fetched #{fetched.size}) → #{DATA_FILE}"
  end

  desc "Mirror the avatars (official-artwork + pixel sprite, normal + shiny) into S3 (RANGE=152-251 narrows)"
  task upload_images: :environment do
    require "aws-sdk-s3"
    bucket = ENV.fetch("POKEMON_S3_BUCKET", "mcritchie-studio-production")
    s3 = Aws::S3::Client.new(region: "us-east-2")
    variants = image_variants
    range = dex_range
    # Slug-keyed for self-describing URLs (e.g. pokemon/73-tentacruel.png). Slugs
    # come from the committed JSON; the source images are still dex-keyed on the CDN.
    rows = JSON.parse(File.read(DATA_FILE)).select { |row| range.cover?(row.fetch("dex")) }
    rows.each do |row|
      dex = row.fetch("dex")
      slug = row.fetch("slug")
      if variants.include?("normal")
        put_image(s3, bucket, "pokemon/#{dex}-#{slug}.png", "#{SPRITE_CDN}/other/official-artwork/#{dex}.png")
        put_image(s3, bucket, "pokemon/#{dex}-#{slug}-sprite.png", "#{SPRITE_CDN}/#{dex}.png")
      end
      if variants.include?("shiny")
        put_image(s3, bucket, "pokemon/#{dex}-#{slug}-shiny.png", "#{SPRITE_CDN}/other/official-artwork/shiny/#{dex}.png")
        put_image(s3, bucket, "pokemon/#{dex}-#{slug}-shiny-sprite.png", "#{SPRITE_CDN}/shiny/#{dex}.png")
      end
      warn "uploaded ##{format('%03d', dex)} #{slug} (#{variants.join('+')})"
    end
    puts "mirrored #{rows.size} Pokémon avatars (#{variants.join('+')}) → s3://#{bucket}/pokemon/"
  end

  # Tighten each avatar: download the ORIGINAL official-artwork from S3, trim its
  # transparent margin to the character's bounding box, add a small uniform margin
  # so it isn't edge-to-edge, and upload the crop to a NEW key
  # (pokemon/<dex>-<slug>-cropped.png). ADDITIVE — the original <dex>-<slug>.png is
  # never touched; it stays the backup (Pokemon#avatar_fallback_url). Crops are
  # cached under tmp/pokemon_crops/ so a re-run skips re-downloading/re-cropping.
  #
  #   LIMIT=3 rake pokemon:crop_and_upload   # smoke-test the first three only
  #   CROP_MARGIN=6% rake pokemon:crop_and_upload
  desc "Crop each avatar to its non-transparent bbox (+margin); upload to <dex>-<slug>-cropped.png (additive)"
  task crop_and_upload: :environment do
    require "aws-sdk-s3"
    bucket = ENV.fetch("POKEMON_S3_BUCKET", "mcritchie-studio-production")
    margin = ENV.fetch("CROP_MARGIN", "5%") # border added after the trim (≈ uniform 5%)
    limit  = ENV["LIMIT"].to_i              # 0 = all; >0 crops only the first N
    cache  = Rails.root.join("tmp/pokemon_crops")
    FileUtils.mkdir_p(cache)

    s3 = Aws::S3::Client.new(region: "us-east-2")
    range = dex_range
    rows = JSON.parse(File.read(DATA_FILE)).select { |row| range.cover?(row.fetch("dex")) }
    rows = rows.first(limit) if limit.positive?

    # "" = the normal art, "-shiny" = the shiny mirror; VARIANTS narrows a run.
    suffixes = []
    suffixes << "" if image_variants.include?("normal")
    suffixes << "-shiny" if image_variants.include?("shiny")

    uploaded = 0
    skipped = []
    rows.each do |row|
      dex = row.fetch("dex")
      slug = row.fetch("slug")
      suffixes.each do |suffix|
        base = "#{dex}-#{slug}#{suffix}"
        original_url = "#{S3_BASE}/#{base}.png"    # the backup — read only
        src_path = cache.join("#{base}.png")
        out_path = cache.join("#{base}-cropped.png")
        key = "pokemon/#{base}-cropped.png"        # the NEW crop key

        begin
          download_png(original_url, src_path) unless File.exist?(src_path)
          crop_to_bbox(src_path, out_path, margin) unless File.exist?(out_path) && File.size(out_path).positive?
          s3.put_object(
            bucket: bucket,
            key: key,
            body: File.binread(out_path),
            content_type: "image/png",
            cache_control: "public, max-age=31536000, immutable"
          )
          uploaded += 1
          warn "cropped+uploaded ##{format('%03d', dex)} #{slug}#{suffix} → #{key} (#{File.size(out_path)} B)"
        rescue StandardError => e
          skipped << "#{base}: #{e.class}: #{e.message}"
          warn "SKIPPED ##{format('%03d', dex)} #{slug}#{suffix}: #{e.class}: #{e.message}"
        end
      end
    end

    puts "cropped+uploaded #{uploaded}/#{rows.size * suffixes.size} → s3://#{bucket}/pokemon/*-cropped.png"
    unless skipped.empty?
      puts "skipped #{skipped.size}:"
      skipped.each { |s| puts "  - #{s}" }
    end
  end

  def get_json(url)
    JSON.parse(Net::HTTP.get(URI(url)))
  end

  # Derive base/evolution/baby for EVERY row from PokéAPI species links
  # (evolves_from_species + is_baby), clipped to the rows present: an
  # out-of-range relative (Munchlax above Snorlax, Magmortar below Magmar)
  # simply doesn't exist here, which is exactly the Gen 1–2 view we want.
  #
  #   base      — the family's spawnable root. Walking parents up from any form
  #               lands on the family base; a baby root hands the crown to its
  #               evolution (Cleffa → Clefairy). Tyrogue (a baby root with THREE
  #               branches) has no single heir and stays self-based — the spawn
  #               pool excludes him via the baby lists instead.
  #   evolution — the slugs this form evolves INTO next (within the set).
  #   baby      — on each base: its family's baby forms (all three Hitmons
  #               carry ["tyrogue"]).
  def stamp_family_fields(rows)
    by_dex = rows.index_by { |row| row["dex"] }
    parent = {}
    is_baby = {}
    rows.each do |row|
      dex = row["dex"]
      species = get_json("#{POKEAPI}/pokemon-species/#{dex}")
      is_baby[dex] = species["is_baby"] == true
      from = species.dig("evolves_from_species", "url").to_s[%r{/(\d+)/?\z}, 1]&.to_i
      parent[dex] = from if from && by_dex.key?(from)
      warn "species ##{format('%03d', dex)} #{row['slug']}#{' (baby)' if is_baby[dex]}"
    end

    children = Hash.new { |hash, key| hash[key] = [] }
    parent.each { |dex, from| children[from] << dex }

    rows.each do |row|
      dex = row["dex"]
      row["base"] = by_dex.fetch(family_base_dex(dex, parent, children, is_baby))["slug"]
      row["evolution"] = children[dex].sort.map { |child| by_dex.fetch(child)["slug"] }
      row["baby"] = []
    end
    rows.each do |row|
      next unless is_baby[row["dex"]]

      children[row["dex"]].each do |child_dex|
        base_slug = by_dex.fetch(child_dex)["base"]
        base_row = rows.find { |candidate| candidate["slug"] == base_slug }
        base_row["baby"] |= [row["slug"]]
      end
    end
  end

  def family_base_dex(dex, parent, children, is_baby)
    path = [dex]
    path << parent[path.last] while parent[path.last]
    root = path.last
    return root unless is_baby[root]
    return path[-2] if path.length > 1 # the first form above the baby

    children[root].one? ? children[root].first : root # Cleffa → Clefairy; Tyrogue stays
  end

  # The dex slice a task works — RANGE=<from>-<to> (e.g. RANGE=152-251), the
  # full 1–251 when unset.
  def dex_range
    spec = ENV["RANGE"].to_s.strip
    return DEX_RANGE if spec.empty?

    from, to = spec.split(/[-.]+/).map { |part| Integer(part) }
    raise ArgumentError, "RANGE=#{spec} (want e.g. 152-251)" unless from&.positive? && to && to >= from

    (from..to)
  end

  def generation_for(dex)
    generation, = GENERATION_RANGES.find { |_, range| range.cover?(dex) }
    generation || raise(ArgumentError, "dex #{dex} outside the known generation ranges")
  end

  # Which artwork variants an image task processes — VARIANTS=shiny (or
  # VARIANTS=normal) narrows a run; the default is both. The shiny-only run is
  # the common re-provision case (the normal art is already mirrored).
  def image_variants
    requested = ENV["VARIANTS"].to_s.split(",").map(&:strip).reject(&:empty?)
    requested.presence || %w[normal shiny]
  end

  # GET a PNG, verifying a 2xx + image content-type so an S3 error XML never gets
  # written to disk (and then cropped into garbage).
  def download_png(url, path)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.get(uri.request_uri) }
    raise "GET #{url} → HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    raise "GET #{url} → content-type #{res.content_type}" unless res.content_type.to_s.start_with?("image/")
    raise "GET #{url} → empty body" if res.body.to_s.bytesize.zero?

    File.binwrite(path, res.body)
  end

  # ImageMagick: trim the transparent padding to the character's bounding box,
  # then pad back a small transparent border (margin) so it isn't edge-to-edge.
  # +repage after each op resets the virtual canvas so the crop is the real frame.
  def crop_to_bbox(src_path, out_path, margin)
    ok = system(
      "magick", src_path.to_s,
      "-trim", "+repage",
      "-bordercolor", "none", "-border", margin, "+repage",
      out_path.to_s
    )
    raise "magick crop failed" unless ok && File.exist?(out_path) && File.size(out_path).positive?
  end

  def put_image(s3, bucket, key, source_url)
    body = Net::HTTP.get(URI(source_url))
    # Long immutable cache — these reference images never change. The bucket is
    # bucket-owner-enforced (ACLs disabled); objects are already public via the
    # bucket's standing PublicReadGetObject policy (arn:.../*), not per-object ACLs.
    s3.put_object(
      bucket: bucket,
      key: key,
      body: body,
      content_type: "image/png",
      cache_control: "public, max-age=31536000, immutable"
    )
  end
end

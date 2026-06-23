# Pokémon reference-data provisioning. Two one-time tasks, run during a rebuild —
# NOT at seed time. The seed (db/seeds/56_pokemon.rb) is DB-only: it reads the
# committed JSON this writes. Mirrors the headshot pattern in
# db/seeds/32_headshot_links.rb (identity/URLs seeded; image bytes uploaded here).
#
#   rake pokemon:fetch          → pull the original 151 from PokéAPI into the JSON
#   rake pokemon:upload_images  → mirror each Pokémon's two avatars into S3
require "net/http"
require "json"

namespace :pokemon do
  POKEAPI = "https://pokeapi.co/api/v2"
  DEX_RANGE = (1..151)
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
    "farfetchd" => "Farfetch'd"
  }.freeze

  desc "Seed/refresh the 151 Pokémon rows from the committed JSON (idempotent; safe on QA/prod)"
  task seed: :environment do
    load Rails.root.join("db/seeds/56_pokemon.rb").to_s
  end

  desc "Pull the original 151 from PokéAPI into db/seeds/data/pokemon.json"
  task fetch: :environment do
    rows = DEX_RANGE.map do |dex|
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
        "generation" => 1,
        "avatar_url" => "#{S3_BASE}/#{dex}-#{slug}.png",
        "sprite_url" => "#{S3_BASE}/#{dex}-#{slug}-sprite.png"
      }
      warn "fetched ##{format('%03d', dex)} #{row['name']}"
      row
    end
    File.write(DATA_FILE, "#{JSON.pretty_generate(rows)}\n")
    puts "wrote #{rows.size} Pokémon → #{DATA_FILE}"
  end

  desc "Mirror the 151 avatars (official-artwork + pixel sprite) into S3"
  task upload_images: :environment do
    require "aws-sdk-s3"
    bucket = ENV.fetch("POKEMON_S3_BUCKET", "mcritchie-studio-production")
    s3 = Aws::S3::Client.new(region: "us-east-2")
    # Slug-keyed for self-describing URLs (e.g. pokemon/73-tentacruel.png). Slugs
    # come from the committed JSON; the source images are still dex-keyed on the CDN.
    JSON.parse(File.read(DATA_FILE)).each do |row|
      dex = row.fetch("dex")
      slug = row.fetch("slug")
      put_image(s3, bucket, "pokemon/#{dex}-#{slug}.png", "#{SPRITE_CDN}/other/official-artwork/#{dex}.png")
      put_image(s3, bucket, "pokemon/#{dex}-#{slug}-sprite.png", "#{SPRITE_CDN}/#{dex}.png")
      warn "uploaded ##{format('%03d', dex)} #{slug}"
    end
    puts "mirrored 151 Pokémon avatars → s3://#{bucket}/pokemon/"
  end

  def get_json(url)
    JSON.parse(Net::HTTP.get(URI(url)))
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

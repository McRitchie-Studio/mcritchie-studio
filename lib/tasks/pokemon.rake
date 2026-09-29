# Pokémon reference-data provisioning. Two one-time tasks, run during a rebuild —
# NOT at seed time. The seed (db/seeds/56_pokemon.rb) is DB-only: it reads the
# committed JSON this writes. Mirrors the headshot pattern in
# db/seeds/32_headshot_links.rb (identity/URLs seeded; image bytes uploaded here).
#
#   rake pokemon:fetch           → pull Gen 1–4 (dex 1–493) from PokéAPI into the JSON
#   rake pokemon:upload_images   → mirror each Pokémon's avatars + sprites into S3
#                                  (plus the female pixel sprites)
#   rake pokemon:crop_and_upload → trim each avatar's transparent margin and
#                                  upload the crop to <dex>-<slug>-cropped.png
#                                  (the original <dex>-<slug>.png is the backup)
#   rake pokemon:prune_missing_art → blank every JSON image URL whose S3 key is
#                                  absent (art missing upstream), so the model's
#                                  fallback chain takes over instead of a 403
#
# Every upload is ADDITIVE ONLY: a key already in the bucket is never overwritten
# or deleted, and a source the CDN does not serve (a 404) is reported, never
# stored. Run the four in that order for a new dex slice:
#
#   RANGE=252-493 rake pokemon:fetch pokemon:upload_images pokemon:crop_and_upload pokemon:prune_missing_art
#
# Both image tasks cover the normal AND shiny art (shiny keys carry a -shiny
# infix); VARIANTS=shiny (or normal) narrows a run to one side. upload_images also
# mirrors the female sprites (VARIANTS=female alone does just those — the
# additive run after a gender fetch). All three tasks
# accept RANGE=<from>-<to> (e.g. RANGE=252-493) to work one dex slice — fetch
# merges the slice into the existing JSON, so a Hoenn–Sinnoh run never rewrites
# (or churns) the committed Kanto and Johto rows' own fields.
#
# PokéAPI and the sprite CDN are shared and rate-limited: requests go through a
# small thread pool (POOL_SIZE) and get_json retries a 429 or 5xx with backoff.
require "net/http"
require "json"
require "fileutils"

namespace :pokemon do
  POKEAPI = "https://pokeapi.co/api/v2"
  DEX_RANGE = (1..493)
  # Which generation each dex slice belongs to — written onto every fetched row.
  GENERATION_RANGES = { 1 => (1..151), 2 => (152..251), 3 => (252..386), 4 => (387..493) }.freeze
  # Concurrent requests against PokéAPI / the sprite CDN — kept small on purpose.
  POOL_SIZE = 4
  # Attempts per PokéAPI request before a 429 / 5xx / network error is fatal.
  FETCH_ATTEMPTS = 5
  DATA_FILE = Rails.root.join("db/seeds/data/pokemon.json")
  # Deterministic-by-dex sources on the PokéAPI sprite CDN.
  SPRITE_CDN = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon".freeze
  # Final home: the bucket's pokemon/ prefix. URLs come from pokemon_image_base.

  # Every JSON field that names an S3 image key.
  IMAGE_URL_FIELDS = %w[
    avatar_url avatar_fallback_url sprite_url
    shiny_avatar_url shiny_avatar_fallback_url shiny_sprite_url
    female_sprite_url shiny_female_sprite_url
  ].freeze

  # Forms PokéAPI flags as babies (species.is_baby) that we deliberately treat as
  # ordinary spawnable bases instead — stamp_family_fields consults this so a
  # re-fetch reproduces the override rather than re-demoting them. Rechecked for
  # Gen 3–4 (tasks/pokemon-gen-3-and-4):
  #   togepi  — kept. It was first kept because Togetic was its only in-range
  #             relative; with Gen 4, Togekiss arrives, and keeping Togepi makes
  #             the line a true three-stage root (Togepi → Togetic → Togekiss)
  #             rather than demoting a form that has spawned since Gen 2 and
  #             churning every live Togepi mascot's family. Pichu, Cleffa,
  #             Igglybuff, Smoochum, Elekid and Magby were always babies and stay
  #             so: each already hands the crown to its one heir.
  #   tyrogue — kept. A branching baby with no single heir: as a base it unifies
  #             the three Hitmon forms into one family that evolves to a random
  #             branch at a gate, instead of three standalone Hitmon bases. Gen 4
  #             adds no Hitmon, so nothing changes.
  # The Gen 3–4 babies (Azurill, Wynaut, Budew, Chingling, Bonsly, Mime Jr.,
  # Happiny, Munchlax, Riolu, Mantyke — as PokéAPI flags them) are NOT listed:
  # each has exactly one heir, so the ordinary rule seats them on its base's baby
  # list, where they never spawn.
  NOT_BABY = %w[togepi tyrogue].freeze

  # Drawable gender FAMILIES: one mascot row whose rolled gender picks the species
  # it wears. PokéAPI splits Nidoran into two species (dex 29 ♀, 32 ♂); the mascot
  # draw treats it as ONE family, `nidoran`, and the gender picks the line
  # (female → Nidorina → Nidoqueen, male → Nidorino → Nidoking). fetch derives the
  # family row from its two forms (see stamp_gender_families); the form rows stay
  # so old tasks carrying nidoran-f / nidoran-m still resolve, and the deck skips
  # them (Pokemon.deck).
  GENDER_FAMILIES = {
    "nidoran" => { "name" => "Nidoran", "female" => "nidoran-f", "male" => "nidoran-m" }
  }.freeze

  # Evolution branches only one gender may take: { from => { into => gender } }.
  # Stamped onto the FROM row as evolution_genders; a slug missing from the fetched
  # set is skipped. fetch also DERIVES the rule from PokéAPI's evolution chains
  # (evolution_details.gender: 1 female, 2 male) and aborts when the two disagree
  # (check_evolution_genders), so this reviewed list cannot drift from the source.
  # A male Combee has no allowed branch and never evolves; Kirlia→Gardevoir and
  # Snorunt→Glalie are open to either gender. The nidoran branches are derived
  # from GENDER_FAMILIES instead.
  EVOLUTION_GENDERS = {
    "kirlia"  => { "gallade" => "male" },
    "snorunt" => { "froslass" => "female" },
    "burmy"   => { "wormadam" => "female", "mothim" => "male" },
    "combee"  => { "vespiquen" => "female" }
  }.freeze

  # The handful of Pokémon whose display name isn't just the title-cased slug.
  DISPLAY_NAMES = {
    "nidoran-f" => "Nidoran♀",
    "nidoran-m" => "Nidoran♂",
    "mr-mime"   => "Mr. Mime",
    "farfetchd" => "Farfetch'd",
    "ho-oh"     => "Ho-Oh",
    "mime-jr"   => "Mime Jr.",
    "porygon-z" => "Porygon-Z"
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

  desc "Pull Gen 1–4 (dex 1–493) from PokéAPI into db/seeds/data/pokemon.json (RANGE=252-493 fetches one slice, merged into the existing file)"
  task fetch: :environment do
    range = dex_range
    existing = File.exist?(DATA_FILE) ? JSON.parse(File.read(DATA_FILE)) : []
    # A family row shares its female form's dex, so it would shadow that form in
    # the dex-keyed family walk; drop it here and re-derive it after the walk.
    existing.reject! { |row| GENDER_FAMILIES.key?(row["slug"]) }
    fetched = pooled_map(range.to_a) do |dex|
      data = get_json("#{POKEAPI}/pokemon/#{dex}")
      # The SPECIES name, not the default form's: Gen 4 names its default forms
      # (wormadam-plant, giratina-altered, shaymin-land, deoxys-normal), and the
      # species is what the evolution chains, the gender rules and the Pokédex
      # talk about. For every Gen 1–2 row the two are the same.
      slug = data.dig("species", "name").presence || data.fetch("name")
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
        "avatar_url" => "#{pokemon_image_base}/#{dex}-#{slug}-cropped.png",
        "avatar_fallback_url" => "#{pokemon_image_base}/#{dex}-#{slug}.png",
        "sprite_url" => "#{pokemon_image_base}/#{dex}-#{slug}-sprite.png",
        # The shiny mirror of the same three — worn when a mascot DRAW rolls
        # shiny (Pokemon.roll_shiny?), provisioned by the same two rakes.
        "shiny_avatar_url" => "#{pokemon_image_base}/#{dex}-#{slug}-shiny-cropped.png",
        "shiny_avatar_fallback_url" => "#{pokemon_image_base}/#{dex}-#{slug}-shiny.png",
        "shiny_sprite_url" => "#{pokemon_image_base}/#{dex}-#{slug}-shiny-sprite.png"
        # gender_rate / has_gender_differences / the female sprites are stamped
        # from the species record in stamp_family_fields.
      }
      warn "fetched ##{format('%03d', dex)} #{row['name']}"
      row
    end
    # Merge the fetched slice into the file: rows outside the slice keep their
    # fetched fields verbatim, so a RANGE=152-251 run cannot churn the committed
    # Kanto rows. Family fields are then (re)derived across the WHOLE set —
    # they are cross-row facts (Johto gave Onix an evolution), not per-row ones.
    rows = (existing.reject { |row| range.cover?(row["dex"]) } + fetched).sort_by { |row| row["dex"] }
    species = fetch_species(rows)
    stamp_family_fields(rows, species)
    check_evolution_genders(rows, derive_evolution_genders(fetch_chains(species)))
    stamp_gender_families(rows)
    stamp_evolution_genders(rows)
    rows.sort_by! { |row| [row["dex"], row["slug"]] }
    File.write(DATA_FILE, "#{JSON.pretty_generate(rows)}\n")
    puts "wrote #{rows.size} Pokémon (fetched #{fetched.size}) → #{DATA_FILE}"
  end

  desc "Mirror the avatars (official-artwork + pixel sprite, normal + shiny, + female sprites) into S3, additively (RANGE=252-493 narrows)"
  task upload_images: :environment do
    require "aws-sdk-s3"
    bucket = pokemon_bucket
    s3 = Studio::S3.client
    # Slug-keyed for self-describing URLs (e.g. pokemon/73-tentacruel.png). Slugs
    # come from the committed JSON; the source images are still dex-keyed on the CDN.
    # Family rows (nidoran) wear their forms' art, so they own no keys to mirror.
    jobs = image_rows(dex_range).flat_map { |row| image_sources(row, image_variants).to_a }
    # ADDITIVE: put_image_if_absent never overwrites a key already in the bucket,
    # and raises on a source the CDN does not serve, so a 404 page is never stored.
    outcomes = pooled_map(jobs) do |key, source|
      [put_image_if_absent(s3, bucket, key, source) ? :uploaded : :present, nil]
    rescue StandardError => e
      [:missing, "#{key} ← #{source}: #{e.message}"]
    end
    tally = outcomes.map(&:first).tally
    tally.default = 0
    missing = outcomes.filter_map(&:last)

    puts "mirrored #{jobs.size} keys (#{image_variants.join('+')}) → s3://#{bucket}/pokemon/: " \
         "#{tally[:uploaded]} uploaded, #{tally[:present]} already present (skipped), #{tally[:missing]} missing upstream"
    missing.sort.each { |line| puts "  - #{line}" }
  end

  # Tighten each avatar: download the ORIGINAL official-artwork from S3, trim its
  # transparent margin to the character's bounding box, add a small uniform margin
  # so it isn't edge-to-edge, and upload the crop to a NEW key
  # (pokemon/<dex>-<slug>-cropped.png). ADDITIVE — the original <dex>-<slug>.png is
  # never touched; it stays the backup (Pokemon#avatar_fallback_url), and a crop
  # key already in the bucket is skipped, never re-uploaded. Crops are cached under
  # tmp/pokemon_crops/ so a re-run skips re-downloading/re-cropping.
  #
  #   LIMIT=3 rake pokemon:crop_and_upload   # smoke-test the first three only
  #   CROP_MARGIN=6% rake pokemon:crop_and_upload
  desc "Crop each avatar to its non-transparent bbox (+margin); upload to <dex>-<slug>-cropped.png (additive)"
  task crop_and_upload: :environment do
    require "aws-sdk-s3"
    bucket = pokemon_bucket
    margin = ENV.fetch("CROP_MARGIN", "5%") # border added after the trim (≈ uniform 5%)
    limit  = ENV["LIMIT"].to_i              # 0 = all; >0 crops only the first N
    cache  = Rails.root.join("tmp/pokemon_crops")
    FileUtils.mkdir_p(cache)

    s3 = Studio::S3.client
    range = dex_range
    rows = image_rows(range)
    rows = rows.first(limit) if limit.positive?

    # "" = the normal art, "-shiny" = the shiny mirror; VARIANTS narrows a run.
    suffixes = []
    suffixes << "" if image_variants.include?("normal")
    suffixes << "-shiny" if image_variants.include?("shiny")

    uploaded = 0
    present = 0
    skipped = []
    rows.each do |row|
      dex = row.fetch("dex")
      slug = row.fetch("slug")
      suffixes.each do |suffix|
        base = "#{dex}-#{slug}#{suffix}"
        original_url = "#{pokemon_image_base}/#{base}.png"    # the backup — read only
        src_path = cache.join("#{base}.png")
        out_path = cache.join("#{base}-cropped.png")
        key = "pokemon/#{base}-cropped.png"        # the NEW crop key

        begin
          if s3_key_exists?(s3, bucket, key)
            present += 1
            next
          end

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

    puts "cropped+uploaded #{uploaded}/#{rows.size * suffixes.size} → s3://#{bucket}/pokemon/*-cropped.png " \
         "(#{present} already present, skipped)"
    unless skipped.empty?
      puts "skipped #{skipped.size}:"
      skipped.each { |s| puts "  - #{s}" }
    end
  end

  desc "Blank every image URL in the JSON whose S3 object is absent (art missing upstream) (RANGE=252-493 narrows)"
  task prune_missing_art: :environment do
    rows = JSON.parse(File.read(DATA_FILE))
    range = dex_range
    urls = rows.select { |row| range.cover?(row["dex"]) }.flat_map { |row| row.values_at(*IMAGE_URL_FIELDS) }
    live = pooled_map(urls.compact.uniq) { |url| [url, public_image?(url)] }.to_h
    pruned = prune_missing_urls(rows, range) { |url| live.fetch(url) }
    File.write(DATA_FILE, "#{JSON.pretty_generate(rows)}\n")
    puts "checked #{live.size} image URLs; blanked #{pruned.size} with no S3 object"
    pruned.each { |line| puts "  - #{line}" }
  end

  # Nil each in-range row's image URL the block says is not live, so the JSON
  # never points at a key that was never uploaded; Pokemon#display_avatar and
  # #display_sprite then fall through to the next art that exists (shiny → normal,
  # crop → original → sprite, female → the ordinary sprite). Returns one
  # "<slug>.<field>" line per URL blanked. A gender family row (nidoran) wears its
  # form's URLs and is pruned by the same rule.
  def prune_missing_urls(rows, range)
    rows.each_with_object([]) do |row, pruned|
      next unless range.cover?(row["dex"])

      IMAGE_URL_FIELDS.each do |field|
        url = row[field]
        next if url.blank? || yield(url)

        row[field] = nil
        pruned << "#{row['slug']}.#{field}"
      end
    end
  end

  # A HEAD against the public bucket URL — the same request a browser makes.
  def public_image?(url)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.head(uri.request_uri) }
    res.is_a?(Net::HTTPSuccess)
  end

  # GET PokéAPI JSON, retrying a 429, a 5xx or a dropped connection with
  # exponential backoff (honouring Retry-After) — the API is shared and
  # rate-limited. Any other non-2xx, or FETCH_ATTEMPTS failures, raises.
  # Where the mirrored images are served from, built from the storage adapter:
  # its public base once one is set (R2), else the PATH-STYLE AWS URL of the
  # upload bucket. Path-style on purpose: the virtual-hosted host
  # `mcritchie-studio-production.s3…` trips Chrome's lookalike-domain warning.
  def pokemon_image_base
    return Studio::S3.url(key: "pokemon") if Studio.s3_public_url.present? || Studio::S3.endpoint

    "https://s3.#{Studio::S3.region}.amazonaws.com/#{pokemon_bucket}/pokemon"
  end

  # The committed JSON serves every environment, so images live in the
  # production bucket unless POKEMON_S3_BUCKET says otherwise.
  def pokemon_bucket
    ENV.fetch("POKEMON_S3_BUCKET", "mcritchie-studio-production")
  end

  def get_json(url)
    (1..FETCH_ATTEMPTS).each do |attempt|
      begin
        res = Net::HTTP.get_response(URI(url))
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError
        raise if attempt == FETCH_ATTEMPTS

        retry_pause(2**attempt)
        next
      end
      return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)
      raise "GET #{url} → HTTP #{res.code}" unless retryable_status?(res.code) && attempt < FETCH_ATTEMPTS

      retry_pause([res["retry-after"].to_i, 2**attempt].max)
    end
  end

  def retryable_status?(code)
    code.to_i == 429 || code.to_i >= 500
  end

  def retry_pause(seconds)
    warn "  retrying in #{seconds}s"
    sleep(seconds)
  end

  # Map `items` through the block on a small pool of POOL_SIZE threads, returning
  # the results in the items' order. The first error raised in a block is
  # re-raised here once the pool drains.
  def pooled_map(items, size: POOL_SIZE)
    queue = Queue.new
    items.each_with_index { |item, index| queue << [item, index] }
    results = Array.new(items.size)
    threads = Array.new([size, items.size].min) do
      Thread.new do
        loop do
          item, index = queue.pop(true)
          results[index] = yield(item)
        rescue ThreadError
          break
        end
      end
    end
    threads.each(&:join)
    results
  end

  # Each row's pokemon-species record, keyed by dex, fetched through the pool.
  def fetch_species(rows)
    dexes = rows.map { |row| row["dex"] }.uniq
    pooled_map(dexes) { |dex| [dex, get_json("#{POKEAPI}/pokemon-species/#{dex}")] }.to_h
  end

  # Every distinct evolution chain the fetched species belong to.
  def fetch_chains(species_by_dex)
    urls = species_by_dex.values.filter_map { |species| species.dig("evolution_chain", "url") }.uniq
    pooled_map(urls) { |url| get_json(url) }
  end

  # { from => { into => gender } } for every chain link PokéAPI gates by gender
  # (evolution_details.gender: 1 female, 2 male). A link is gated only when every
  # way to take it names the same gender.
  def derive_evolution_genders(chains)
    genders = {}
    walk = lambda do |node|
      from = node.dig("species", "name")
      Array(node["evolves_to"]).each do |child|
        codes = Array(child["evolution_details"]).map { |detail| detail["gender"] }.uniq
        gender = { 1 => "female", 2 => "male" }[codes.first] if codes.size == 1 # not .one?: it skips nil
        (genders[from] ||= {})[child.dig("species", "name")] = gender if gender
        walk.call(child)
      end
    end
    chains.each { |chain| walk.call(chain.fetch("chain")) }
    genders
  end

  # Abort the fetch when PokéAPI's gender gates, clipped to the rows present,
  # disagree with the reviewed EVOLUTION_GENDERS — a new gate (or a lost one) is a
  # decision for a person, not a silent data change.
  def check_evolution_genders(rows, derived)
    slugs = rows.to_set { |row| row["slug"] }
    clip = lambda do |map|
      map.filter_map do |from, branches|
        kept = branches.select { |into, _| slugs.include?(from) && slugs.include?(into) }
        [from, kept] unless kept.empty?
      end.to_h
    end
    expected = clip.call(EVOLUTION_GENDERS)
    actual = clip.call(derived)
    return if expected == actual

    raise "PokéAPI gender gates #{actual.inspect} differ from EVOLUTION_GENDERS #{expected.inspect}"
  end

  # Derive base/evolution/baby for EVERY row from its PokéAPI species record
  # (evolves_from_species + is_baby; `species_by_dex` from fetch_species), clipped
  # to the rows present: an out-of-range relative simply doesn't exist here. Over
  # dex 1–493 that is how Gen 4 extends Gen 1–2 lines (Electabuzz → Electivire)
  # and seats Gen 3–4 babies on older bases (Munchlax on Snorlax), with no list
  # typed by hand.
  #
  #   base      — the family's spawnable root. Walking parents up from any form
  #               lands on the family base; a baby root hands the crown to its
  #               evolution (Cleffa → Clefairy). Tyrogue (a baby root with THREE
  #               branches) has no single heir and stays self-based — the spawn
  #               pool excludes him via the baby lists instead.
  #   evolution — the slugs this form evolves INTO next (within the set).
  #   baby      — on each base: its family's baby forms (all three Hitmons
  #               carry ["tyrogue"]).
  def stamp_family_fields(rows, species_by_dex)
    by_dex = rows.index_by { |row| row["dex"] }
    parent = {}
    is_baby = {}
    rows.each do |row|
      dex = row["dex"]
      species = species_by_dex.fetch(dex)
      is_baby[dex] = species["is_baby"] == true && !NOT_BABY.include?(row["slug"])
      stamp_gender_fields(row, species)
      from = species.dig("evolves_from_species", "url").to_s[%r{/(\d+)/?\z}, 1]&.to_i
      parent[dex] = from if from && by_dex.key?(from)
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

  # The species' gender facts, off the pokemon-species record fetch_species
  # fetched: gender_rate (eighths-female; -1 genderless) and whether it has
  # a distinct female look. Only a species with one gets female sprite URLs — the
  # deterministic S3 keys `rake pokemon:upload_images` mirrors them to.
  def stamp_gender_fields(row, species)
    dex = row["dex"]
    slug = row["slug"]
    differs = species["has_gender_differences"] == true
    row["gender_rate"] = species.fetch("gender_rate")
    row["has_gender_differences"] = differs
    row["female_sprite_url"] = (differs ? "#{pokemon_image_base}/#{dex}-#{slug}-female-sprite.png" : nil)
    row["shiny_female_sprite_url"] = (differs ? "#{pokemon_image_base}/#{dex}-#{slug}-shiny-female-sprite.png" : nil)
  end

  # Add each GENDER_FAMILIES row, built from its female form (its dex, types,
  # stats and art — the male art is worn through gender_forms), and re-root both
  # forms' descendants on the family so the whole line is one evolution tree.
  # Each form row keeps its own base + evolution, so an old task still carrying
  # nidoran-f evolves to Nidorina exactly as before. Idempotent over a re-fetch:
  # an existing family row is replaced, never duplicated.
  def stamp_gender_families(rows)
    GENDER_FAMILIES.each do |family, spec|
      forms = Pokemon::GENDERS.to_h { |gender| [gender, rows.find { |row| row["slug"] == spec.fetch(gender) }] }
      next if forms.values.any?(&:nil?)

      rows.reject! { |row| row["slug"] == family }
      female = forms.fetch("female")
      evolution_genders = forms.each_with_object({}) do |(gender, form), map|
        Array(form["evolution"]).each { |child| map[child] = gender }
      end
      rows << female.merge(
        "name" => spec.fetch("name"),
        "slug" => family,
        "base" => family,
        "evolution" => evolution_genders.keys,
        "baby" => [],
        # Either form, evenly — the family draws Nidoran♀ and Nidoran♂ alike.
        "gender_rate" => 4,
        "has_gender_differences" => false,
        "female_sprite_url" => nil,
        "shiny_female_sprite_url" => nil,
        "gender_forms" => Pokemon::GENDERS.to_h { |gender| [gender, spec.fetch(gender)] },
        "evolution_genders" => evolution_genders
      )
      form_slugs = forms.values.map { |form| form["slug"] }
      rows.each do |row|
        next if form_slugs.include?(row["slug"]) || row["slug"] == family

        row["base"] = family if form_slugs.include?(row["base"])
      end
    end
  end

  # Stamp EVOLUTION_GENDERS onto each present FROM row, keeping only the branches
  # whose target is also present (a RANGE=1-251 file has no Gallade to gate).
  def stamp_evolution_genders(rows)
    slugs = rows.to_set { |row| row["slug"] }
    EVOLUTION_GENDERS.each do |from, branches|
      row = rows.find { |candidate| candidate["slug"] == from }
      next unless row

      present = branches.select { |into, _| slugs.include?(into) }
      row["evolution_genders"] = present unless present.empty?
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

  # The dex slice a task works — RANGE=<from>-<to> (e.g. RANGE=252-493), the
  # full DEX_RANGE (1–493) when unset.
  def dex_range
    spec = ENV["RANGE"].to_s.strip
    return DEX_RANGE if spec.empty?

    from, to = spec.split(/[-.]+/).map { |part| Integer(part) }
    raise ArgumentError, "RANGE=#{spec} (want e.g. 252-493)" unless from&.positive? && to && to >= from

    (from..to)
  end

  def generation_for(dex)
    generation, = GENERATION_RANGES.find { |_, range| range.cover?(dex) }
    generation || raise(ArgumentError, "dex #{dex} outside the known generation ranges")
  end

  # Which artwork variants an image task processes — VARIANTS=shiny (or
  # VARIANTS=normal, VARIANTS=female) narrows a run; the default is all three.
  # The shiny-only run is the common re-provision case (the normal art is already
  # mirrored); female is upload_images-only (crop_and_upload has no female art).
  def image_variants
    requested = ENV["VARIANTS"].to_s.split(",").map(&:strip).reject(&:empty?)
    requested.presence || %w[normal shiny female]
  end

  # The committed rows an image task works: the dex slice, minus the gender
  # FAMILY rows, whose art is their forms' keys (nidoran wears 29-nidoran-f-*).
  def image_rows(range)
    JSON.parse(File.read(DATA_FILE)).select do |row|
      range.cover?(row.fetch("dex")) && row["gender_forms"].blank?
    end
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

  # { S3 key => CDN source } for one row's art in the requested variants: the
  # official artwork + pixel sprite (normal and/or shiny), and — for a species with
  # a distinct female look — the female pixel sprites. Official artwork has no
  # female variant.
  def image_sources(row, variants)
    base = "pokemon/#{row.fetch('dex')}-#{row.fetch('slug')}"
    dex = row.fetch("dex")
    sources = {}
    if variants.include?("normal")
      sources["#{base}.png"] = "#{SPRITE_CDN}/other/official-artwork/#{dex}.png"
      sources["#{base}-sprite.png"] = "#{SPRITE_CDN}/#{dex}.png"
    end
    if variants.include?("shiny")
      sources["#{base}-shiny.png"] = "#{SPRITE_CDN}/other/official-artwork/shiny/#{dex}.png"
      sources["#{base}-shiny-sprite.png"] = "#{SPRITE_CDN}/shiny/#{dex}.png"
    end
    if variants.include?("female") && row["has_gender_differences"]
      sources["#{base}-female-sprite.png"] = "#{SPRITE_CDN}/female/#{dex}.png"
      sources["#{base}-shiny-female-sprite.png"] = "#{SPRITE_CDN}/shiny/female/#{dex}.png"
    end
    sources
  end

  def s3_key_exists?(s3, bucket, key)
    s3.head_object(bucket: bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    false
  end

  # ADDITIVE upload: PUT only when the key is absent, so a re-run never
  # overwrites (or churns the cache of) an object already served. Returns true
  # when it uploaded, false when the key was already there. The source is checked
  # like download_png, so a CDN 404 page is never stored as an image. Long
  # immutable cache — these reference images never change. The bucket is
  # bucket-owner-enforced (ACLs disabled); objects are public via the bucket's
  # standing PublicReadGetObject policy, not per-object ACLs.
  def put_image_if_absent(s3, bucket, key, source_url)
    if s3_key_exists?(s3, bucket, key)
      warn "  exists, skipped: #{key}"
      return false
    end

    res = Net::HTTP.get_response(URI(source_url))
    raise "GET #{source_url} → HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    raise "GET #{source_url} → content-type #{res.content_type}" unless res.content_type.to_s.start_with?("image/")

    s3.put_object(bucket: bucket, key: key, body: res.body, content_type: "image/png",
                  cache_control: "public, max-age=31536000, immutable")
    true
  end
end

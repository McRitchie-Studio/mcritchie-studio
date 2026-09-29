# Rewrites the hub's STORED absolute S3 URLs onto a new public base, for the
# S3 -> R2 cutover (docs/agents/system/asset-library-plan.md, Wave 2). Run by
# `rake s3_urls:rewrite[<base>]` only after the objects are copied to R2.
#
# Only a URL that STARTS with our bucket's host is touched (path-style or
# virtual-hosted); external hosts, other buckets and URLs that merely embed ours
# in a query string stay put. Dry run unless apply: true. Idempotent: a rewritten
# URL no longer matches, so a re-run finds nothing.
#
# The targets are every place production stores our bucket's URL (measured
# 2026-09-29). Log prose (tasks.metadata, agent_actions, ...) quotes URLs as
# history and is deliberately left alone.
class S3UrlRewrite
  DEFAULT_BUCKET = "mcritchie-studio-production".freeze

  POKEMON_IMAGE_COLUMNS = %w[
    avatar_url avatar_fallback_url sprite_url
    shiny_avatar_url shiny_avatar_fallback_url shiny_sprite_url
    female_sprite_url shiny_female_sprite_url
  ].freeze

  # [model, column] pairs holding one URL each.
  COLUMN_TARGETS = [
    *POKEMON_IMAGE_COLUMNS.map { |column| ["Pokemon", column] },
    ["Artifact", "image_url"],
    # Empty today, but Content::GenerateLineupAssets stores what Studio::S3.upload
    # returns, so rows written before the cutover carry S3 URLs.
    ["Content", "hook_image_url"],
    ["Content", "final_video_url"]
  ].freeze

  # [model, jsonb column, path] — one URL at a path inside a jsonb document.
  JSON_TARGETS = [
    ["TaskEvent", "metadata", %w[mascot avatar]]
  ].freeze

  # Pre-filter so the Ruby matcher only sees candidate rows.
  CANDIDATE = "%amazonaws.com%".freeze

  # s3.amazonaws.com · s3.<region>.amazonaws.com · s3-<region>.amazonaws.com
  S3_HOST = 's3(?:[.-][a-z0-9-]+)?\.amazonaws\.com'.freeze

  attr_reader :base

  def self.rewrite_url(url, base:, bucket: DEFAULT_BUCKET)
    new(base: base, bucket: bucket).rewrite_url(url)
  end

  def initialize(base:, bucket: DEFAULT_BUCKET)
    unless base.is_a?(String) && base.match?(%r{\Ahttps://[^/\s]+})
      raise ArgumentError, "base must be an absolute https URL (e.g. https://assets.mcritchie.studio), got #{base.inspect}"
    end

    @base = base.chomp("/")
    bucket = Regexp.escape(bucket.to_s)
    @pattern = %r{\Ahttps?://(?:#{S3_HOST}/#{bucket}|#{bucket}\.#{S3_HOST})/(?<key>.*)\z}m
  end

  # The URL on the new base, or nil when it is not our bucket's URL.
  def rewrite_url(url)
    match = @pattern.match(url) if url.is_a?(String)
    match && "#{base}/#{match[:key]}"
  end

  # Rewrites every target (or counts them on a dry run). Returns
  # { "table.column" => rows } and prints the same, one line per target.
  def call(apply: false, io: $stdout)
    io.puts(apply ? "APPLIED — rewriting onto #{base}" : "DRY RUN — nothing written (APPLY=1 to write); base #{base}")
    counts = {}
    COLUMN_TARGETS.each do |model_name, column|
      model = model_name.constantize
      counts["#{model.table_name}.#{column}"] = rewrite_column(model, column, apply)
    end
    JSON_TARGETS.each do |model_name, column, path|
      model = model_name.constantize
      counts["#{model.table_name}.#{column}->#{path.join('->')}"] = rewrite_json(model, column, path, apply)
    end
    width = counts.keys.map(&:length).max
    counts.each { |label, rows| io.puts("  #{label.ljust(width)}  #{rows}") }
    counts
  end

  # Rewrites the image URL fields of pokemon seed rows (db/seeds/data/pokemon.json)
  # in place, so a re-seed after the cutover does not restore the S3 URLs.
  # Returns the number of fields changed.
  def rewrite_seed_rows(rows)
    rows.sum do |row|
      POKEMON_IMAGE_COLUMNS.count do |field|
        rewritten = rewrite_url(row[field])
        row[field] = rewritten if rewritten
        rewritten
      end
    end
  end

  private

  # One UPDATE per distinct old URL: the mapping stays in Ruby (one matcher),
  # the writes stay set-based, and update_all skips callbacks and timestamps.
  def rewrite_column(model, column, apply)
    attr = model.arel_table[column]
    mapping = rewrites_for(model.where(attr.matches(CANDIDATE)).distinct.pluck(column))
    return 0 if mapping.empty?

    rows = model.where(column => mapping.keys).count
    if apply
      model.transaction do
        mapping.each { |old, new| model.where(column => old).update_all(column => new) }
      end
    end
    rows
  end

  def rewrite_json(model, column, path, apply)
    conn = model.connection
    pg_path = "{#{path.join(',')}}"
    expr = "#{conn.quote_column_name(column)} #>> #{conn.quote(pg_path)}"
    mapping = rewrites_for(model.where("#{expr} LIKE ?", CANDIDATE).distinct.pluck(Arel.sql(expr)))
    return 0 if mapping.empty?

    rows = model.where("#{expr} IN (?)", mapping.keys).count
    if apply
      set = "#{conn.quote_column_name(column)} = jsonb_set(#{conn.quote_column_name(column)}, ?::text[], to_jsonb(?::text))"
      model.transaction do
        mapping.each { |old, new| model.where("#{expr} = ?", old).update_all([set, pg_path, new]) }
      end
    end
    rows
  end

  def rewrites_for(urls)
    urls.each_with_object({}) do |old, mapping|
      new = rewrite_url(old)
      mapping[old] = new if new
    end
  end
end

# frozen_string_literal: true

module EmailImages
  # ONE BRAND'S KIT for email header art, read from config/email_brand_kits.yml.
  #
  # Loaded the way ImageGeneration::Registry loads its YAML: safe_load_file with
  # no permitted classes, memoized everywhere except development.
  class BrandKit
    PATH = Rails.root.join("config", "email_brand_kits.yml")

    Preset = Struct.new(:key, :label, :width, :height, :generate_size, keyword_init: true)

    # ONE REFERENCE IMAGE, from either source: `yaml` (a file under public/ in
    # this repo, named in config/email_brand_kits.yml) or `upload` (an
    # EmailBrandReference row, stored in our bucket). Everything that shows or
    # sends a reference reads this one shape.
    Reference = Struct.new(:path, :role, :origin, :label, :note, :url, :slug, :uploaded_by, :uploaded_at,
                           keyword_init: true) do
      def yaml? = origin == "yaml"
      def upload? = origin == "upload"
      def absolute_path = (Rails.root.join(path) if yaml?)
      def exists? = yaml? ? File.file?(absolute_path) : url.present?

      # Where the page shows it: the public/ path in this app, or our bucket's URL.
      def display_url = yaml? ? "/#{path.delete_prefix('public/')}" : url

      # Where it came from, for the page and the CLI: the repo path, or the row.
      def source = yaml? ? path : "upload #{slug}"

      # The reference handed to the generator inline, so a desk, CI and
      # production all read the same bytes from the repo and no reference
      # depends on a deployed URL. YAML references only.
      def data_uri
        raise ArgumentError, "#{source} is an upload; hand the generator its url" unless yaml?

        ext = File.extname(path).delete(".").downcase
        type = { "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "webp" => "image/webp" }.fetch(ext, "image/png")
        "data:#{type};base64,#{Base64.strict_encode64(File.binread(absolute_path))}"
      end

      # What the adapter is given: a YAML reference inline, an upload as our
      # bucket's URL (the adapter fetches and inlines it under its size cap).
      def generator_input = yaml? ? data_uri : url
    end

    class UnknownKit < StandardError; end

    # THE ORDER THE GENERATOR PREFERS ROLES IN when it cannot take every
    # reference. The identity marks first, then the look, then the rest.
    ROLE_PRIORITY = %w[mascot logo style product other].freeze

    # HOW MANY REFERENCES A ROW IS OFFERED. A row whose reference_arity is
    # `one` takes one (the adapters already cut to the first). A `many` row is
    # offered at most four: every reference is base64'd into the request and
    # billed as input, so the cap bounds a round's spend and request size while
    # leaving room for the kit's base pair plus two added references.
    REFERENCE_LIMITS = { "one" => 1 }.freeze
    DEFAULT_REFERENCE_LIMIT = 4

    attr_reader :key, :label, :app, :palette, :base_references, :style, :negative, :font

    def initialize(key, attrs)
      @key = key.to_s
      @label = attrs[:label].to_s
      @app = attrs[:app].to_s
      @palette = (attrs[:palette] || {}).transform_keys(&:to_s)
      @base_references = Array(attrs[:references]).map do |r|
        Reference.new(path: r[:path].to_s, role: r[:role].to_s, origin: "yaml", label: File.basename(r[:path].to_s))
      end
      @style = attrs[:style].to_s.squish
      @negative = attrs[:negative].to_s.squish
      @font = attrs[:font].to_s
    end

    # THE KIT'S REFERENCES, MERGED IN ONE PLACE: the YAML references in file
    # order, then the active uploaded ones, newest first. Archived uploads are
    # left out. Read once per kit instance.
    def references = base_references + uploaded_references

    def uploaded_references
      @uploaded_references ||= EmailBrandReference.active.where(brand_kit: key).newest_first.map do |row|
        Reference.new(path: nil, role: row.role, origin: "upload", label: row.label, note: row.note,
                      url: row.image_url, slug: row.slug, uploaded_by: row.uploaded_by, uploaded_at: row.created_at)
      end
    end

    # WHICH REFERENCES A ROUND SENDS, in the order it sends them. Deterministic:
    # the same kit and limit always give the same list.
    #
    #   1. The kit's first YAML reference leads, always: it is the brand's
    #      identity (the gator, the chest, the mark) and the prompt names it as
    #      "the first reference image".
    #   2. Then one reference for each role the lead does not already cover,
    #      in ROLE_PRIORITY order, so a pile of mascot uploads never crowds out
    #      the style anchor. Within a role the YAML reference comes first, else
    #      the newest upload.
    #   3. Then every remaining reference, in ROLE_PRIORITY order, YAML before
    #      uploads, uploads newest first, until the limit is reached.
    def generator_references(limit: DEFAULT_REFERENCE_LIMIT)
      limit = limit.to_i
      return [] if limit <= 0

      lead = base_references.first
      rest = references.reject { |ref| ref.equal?(lead) }
                       .each_with_index.sort_by { |ref, i| [role_rank(ref.role), i] }.map(&:first)
      firsts = rest.uniq(&:role).reject { |ref| ref.role == lead&.role }
      chosen = [lead].compact + firsts + rest.reject { |ref| firsts.any? { |f| f.equal?(ref) } }
      chosen.first(limit)
    end

    def role_rank(role) = ROLE_PRIORITY.index(role.to_s) || ROLE_PRIORITY.size

    def self.reference_limit(row) = REFERENCE_LIMITS.fetch(row&.reference_arity.to_s, DEFAULT_REFERENCE_LIMIT)

    class << self
      def all = config[:kits].map { |key, attrs| new(key, attrs || {}) }
      def keys = all.map(&:key)
      def find(key) = all.find { |kit| kit.key == key.to_s }
      def find!(key) = find(key) || raise(UnknownKit, "No email brand kit #{key.inspect} in #{PATH}")

      def presets
        config[:presets].map do |key, attrs|
          Preset.new(key: key.to_s, label: attrs[:label].to_s, width: attrs[:width].to_i,
                     height: attrs[:height].to_i, generate_size: attrs[:generate_size].to_s)
        end
      end

      def preset(key) = presets.find { |p| p.key == key.to_s }
      def defaults = config[:defaults] || {}
      def candidates_per_round = defaults.fetch(:candidates_per_round, 2).to_i
      def max_rounds = defaults.fetch(:max_rounds, 4).to_i
      def max_bytes = defaults.fetch(:max_bytes, 300_000).to_i

      def reload!
        @config = nil
        config
      end

      private

      def config
        return load_config if Rails.env.development?

        @config ||= load_config
      end

      def load_config
        raw = YAML.safe_load_file(PATH, permitted_classes: [], aliases: false) || {}
        raw = raw.deep_symbolize_keys
        { defaults: raw[:defaults] || {}, presets: raw[:presets] || {}, kits: raw[:kits] || {} }
      end
    end
  end
end

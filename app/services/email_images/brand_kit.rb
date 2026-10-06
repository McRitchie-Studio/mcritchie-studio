# frozen_string_literal: true

module EmailImages
  # ONE BRAND'S KIT for email header art, read from config/email_brand_kits.yml.
  #
  # Loaded the way ImageGeneration::Registry loads its YAML: safe_load_file with
  # no permitted classes, memoized everywhere except development.
  class BrandKit
    PATH = Rails.root.join("config", "email_brand_kits.yml")

    Preset = Struct.new(:key, :label, :width, :height, :generate_size, keyword_init: true)
    Reference = Struct.new(:path, :role, keyword_init: true) do
      def absolute_path = Rails.root.join(path)
      def exists? = File.file?(absolute_path)

      # The reference handed to the generator inline, so a desk, CI and
      # production all read the same bytes from the repo and no reference
      # depends on a deployed URL.
      def data_uri
        ext = File.extname(path).delete(".").downcase
        type = { "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "webp" => "image/webp" }.fetch(ext, "image/png")
        "data:#{type};base64,#{Base64.strict_encode64(File.binread(absolute_path))}"
      end
    end

    class UnknownKit < StandardError; end

    attr_reader :key, :label, :app, :palette, :references, :style, :negative, :font

    def initialize(key, attrs)
      @key = key.to_s
      @label = attrs[:label].to_s
      @app = attrs[:app].to_s
      @palette = (attrs[:palette] || {}).transform_keys(&:to_s)
      @references = Array(attrs[:references]).map { |r| Reference.new(path: r[:path].to_s, role: r[:role].to_s) }
      @style = attrs[:style].to_s.squish
      @negative = attrs[:negative].to_s.squish
      @font = attrs[:font].to_s
    end

    def reference_data_uris = references.map(&:data_uri)

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

module Media
  # config/agent_media.yml, read into the shape Media.home asks: the defaults,
  # each medium's block (enabled, fallback, named channels), and the purpose,
  # app and soul entries. Keys are Strings. Tests build one from a Hash and swap
  # it in with `Media::Config.current=`.
  class Config
    PATH = Rails.root.join("config/agent_media.yml")
    LEVELS = %w[purposes souls apps].freeze

    def self.load(path = PATH)
      new(YAML.safe_load_file(path, aliases: false) || {})
    end

    class << self
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(config)
      @config = config.to_h.deep_stringify_keys
    end

    def defaults = (@config["defaults"] || {})

    def default_medium = defaults["medium"].to_s.presence

    # The medium's block, or nil when the file names none.
    def medium(key) = @config[key.to_s].is_a?(Hash) ? @config[key.to_s] : nil

    def enabled?(key) = medium(key)&.fetch("enabled", false) == true

    # Where a skipped medium falls to: its own `fallback`, else defaults.fallback.
    def fallback(key) = (medium(key) || {})["fallback"].to_s.presence || defaults["fallback"].to_s.presence

    # A named channel's spec on a medium ({ "id" => … } or { "webhook_env" => … }), or nil.
    def channel(medium_key, name)
      return nil if name.blank?

      spec = (medium(medium_key) || {}).dig("channels", name.to_s)
      spec.is_a?(Hash) ? spec : nil
    end

    # The entry for `name` under purposes / souls / apps, or nil.
    def entry(level, name)
      return nil if name.blank?

      value = (@config[level.to_s] || {})[name.to_s]
      value.is_a?(Hash) ? value : nil
    end
  end
end

# frozen_string_literal: true

require "yaml"
require "time"

module Devops
  # The three OPERATOR WINDOWS (docs/agents/system/devops-v3-design.md section 6):
  # the minutes Alex gives himself to answer a UI approval, an escalation, and a
  # production-authority request before the pipeline proceeds on a defined
  # default. Every window here is DERIVED — a timestamp the task or release
  # already carries plus a length from config/release_builder.yml — so there is
  # no window column to keep in step, and changing a length in the YAML moves
  # every countdown on the board at once.
  #
  # Rails-free on purpose, like Release::Cli: bin/release reads the production
  # length and the ship mode from here without booting the app, and the model
  # layer (Task#operator_windows, Release#ship_authorization_window) hands the
  # same math to the board card and the task API. Times are plain Ruby Time; a
  # caller inside Rails passes Time.current.
  module Windows
    module_function

    CONFIG_PATH = File.expand_path("../../../config/release_builder.yml", __dir__)

    KINDS = %w[approval escalation production].freeze
    DEFAULT_MINUTES = { "approval" => 10, "escalation" => 20, "production" => 30 }.freeze

    # The ship modes `bin/release ship --mode` accepts; `production_ship.mode`
    # in the YAML picks the default for a launch that names none.
    MODES = %w[ask timed auto].freeze
    DEFAULT_MODE = "timed"

    # A dependency block whose summary leads with this is the OPERATOR's blocker
    # (address-blocker.md, arbitrate-block.md step 8) — the only block that
    # carries a window.
    ESCALATION_PREFIX = "Escalated:"

    # What the chip says once the clock reaches zero, per kind. Each names the
    # DEFAULT the pipeline proceeds on, so a lapsed chip is a statement, not a
    # blank.
    LAPSED_LABELS = {
      "approval"   => "unanswered, proceeding",
      "escalation" => "lapsed, recommendation stands",
      "production" => "lapsed, shipping on green"
    }.freeze

    # One derived window. `opened_at` is the timestamp it derives from (the
    # request, the block, the ship request); `ends_at` is opened_at + minutes.
    Window = Struct.new(:kind, :opened_at, :ends_at, :minutes, keyword_init: true) do
      def remaining_seconds(now)
        [(ends_at - now).ceil, 0].max
      end

      def lapsed?(now)
        now >= ends_at
      end

      # "mm:ss" while the clock runs. Mirrors the client ticker's window mode in
      # tasks/_release_ticker so the server paint and the first tick agree.
      def clock(now)
        Windows.format_clock(remaining_seconds(now))
      end

      def lapsed_label
        LAPSED_LABELS.fetch(kind)
      end

      def label(now)
        lapsed?(now) ? lapsed_label : clock(now)
      end

      # The JSON the task API carries under `windows` — what `bin/task
      # wait-window` polls. ISO-8601 UTC times, so a CLI on any clock reads them.
      def to_h(now = Time.now)
        {
          "kind" => kind,
          "opened_at" => opened_at.utc.iso8601,
          "ends_at" => ends_at.utc.iso8601,
          "minutes" => minutes,
          "remaining_seconds" => remaining_seconds(now),
          "lapsed" => lapsed?(now),
          "label" => label(now)
        }
      end
    end

    def format_clock(seconds)
      seconds = [seconds.to_i, 0].max
      format("%02d:%02d", seconds / 60, seconds % 60)
    end

    # --- config ---------------------------------------------------------------

    def config(path = CONFIG_PATH)
      @config ||= {}
      @config[path] ||= (YAML.safe_load_file(path) || {})
    end

    def reload!
      @config = nil
    end

    # Minutes for one kind, from `operator_windows` in the YAML; the design's
    # numbers when the key is absent. A non-positive or unreadable value is a
    # config error, not a zero-length window — refused rather than substituted.
    def minutes(kind, config = self.config)
      kind = kind.to_s
      raise ArgumentError, "unknown operator window #{kind.inspect} (known: #{KINDS.join(', ')})" unless KINDS.include?(kind)

      raw = (config["operator_windows"] || {})["#{kind}_minutes"]
      return DEFAULT_MINUTES.fetch(kind) if raw.nil?

      value = Integer(raw, exception: false)
      raise ArgumentError, "operator_windows.#{kind}_minutes must be a positive integer, got #{raw.inspect}" if value.nil? || value <= 0

      value
    end

    # `production_ship.mode` from the YAML — the default for a `bin/release ship`
    # that passes no --mode. A value outside MODES is refused: a typo that fell
    # back to `timed` in silence would ship on a policy nobody wrote.
    def production_ship_mode(config = self.config)
      raw = (config["production_ship"] || {})["mode"]
      return DEFAULT_MODE if raw.nil? || raw.to_s.strip.empty?

      validate_mode!(raw, source: "production_ship.mode")
    end

    def validate_mode!(value, source: "--mode")
      mode = value.to_s.strip.downcase
      return mode if MODES.include?(mode)

      raise ArgumentError, "#{source} must be one of #{MODES.join('|')}, got #{value.inspect}"
    end

    # --- the three windows ----------------------------------------------------

    # The UI-approval window: open while the request is `waiting`, from the
    # moment it was posted. nil when nothing is waiting or the request carries
    # no timestamp (a legacy row) — no timestamp, no clock.
    def approval(requested_at:, waiting:, config: self.config)
      return nil unless waiting

      opened = parse_time(requested_at)
      return nil unless opened

      build("approval", opened, config)
    end

    # The escalation window: a LIVE dependency block whose summary leads
    # `Escalated:`. Any other block — rework, environment, a dependency on a gem
    # — is the builder's or the desk's, and carries no operator clock.
    def escalation(blocked_at:, block_kind:, summary:, config: self.config)
      return nil unless escalation?(block_kind: block_kind, summary: summary)

      opened = parse_time(blocked_at)
      return nil unless opened

      build("escalation", opened, config)
    end

    def escalation?(block_kind:, summary:)
      block_kind.to_s == "dependency" && summary.to_s.lstrip.start_with?(ESCALATION_PREFIX)
    end

    # The production-authority window, from the moment the ship request was
    # posted on the release.
    def production(requested_at:, config: self.config)
      opened = parse_time(requested_at)
      return nil unless opened

      build("production", opened, config)
    end

    # Every open window a TASK carries, escalation first: an escalation is the
    # operator's own blocker and outranks a pending demo approval on the same
    # card. Duck-typed over the Task (or a Hash shaped like the task API), and
    # takes the unresolved block Activity separately because the card and the
    # API both preload it.
    def for_task(task, unresolved: nil, config: self.config)
      devops = read(task, "devops") || read(read(task, "metadata"), "devops") || {}
      waiting = read(devops, "approval_status").to_s == "waiting"
      blocked_at = read(task, "blocked_at")
      live_block = !blocked_at.nil? && read(task, "stage").to_s == "building"
      summary = unresolved.respond_to?(:block_summary) ? unresolved.block_summary : read(unresolved, "summary")

      [
        (escalation(blocked_at: blocked_at, block_kind: read(task, "block_kind"), summary: summary, config: config) if live_block),
        approval(requested_at: read(devops, "approval_requested_at"), waiting: waiting, config: config)
      ].compact
    end

    def build(kind, opened_at, config)
      mins = minutes(kind, config)
      Window.new(kind: kind, opened_at: opened_at, ends_at: opened_at + (mins * 60), minutes: mins)
    end

    def parse_time(value)
      case value
      when nil then nil
      when Time then value
      else
        return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

        text = value.to_s.strip
        text.empty? ? nil : Time.iso8601(text)
      end
    rescue ArgumentError
      nil
    end

    def read(source, key)
      return nil if source.nil?
      return source.public_send(key) if !source.is_a?(Hash) && source.respond_to?(key)
      return nil unless source.respond_to?(:[])

      source[key.to_s] || source[key.to_sym]
    rescue StandardError
      nil
    end
  end
end

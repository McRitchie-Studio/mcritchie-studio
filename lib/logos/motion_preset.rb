# frozen_string_literal: true

module Logos
  # A LOGO MOTION PRESET (task logo-motion-presets; epic logo-motion, phase 1): one of the motions Alex McRitchie picked on
  # Logo Motion Lab II (2026-10-28), built once and played on any brand's own kit parts by the brand page's Motion tab
  # (app/javascript/logo_motion.js, which measures the parts at runtime). This class is the list the page offers and the
  # kit's motion choice is checked against: each preset's key, the idea it came from, its title, one sentence on what
  # it does, and which brands can play it. No preset has per-brand code.
  #
  #   Logos::MotionPreset.for("welding").map(&:key)      # every preset but :weight_flick (traced lettering)
  #   Logos::MotionPreset.check("turf", preset: "weight_flick", logo: "stacked")   # => { "preset" => …, "logo" => … }
  #
  # The logo a preset plays on is the kit's Navbar Logo or its Stacked Logo (LOGOS); every preset plays on both.
  class MotionPreset
    Error = NavbarLogo::Error

    # The logos a motion plays on, as the Motion tab's Logo control names them.
    LOGOS = { navbar: "Navbar Logo", stacked: "Stacked Logo" }.freeze

    attr_reader :key, :idea, :title, :note

    def initialize(key, idea:, title:, note:, weights: false)
      @key = key
      @idea = idea
      @title = title
      @note = note
      @weights = weights
    end

    # True when the preset needs lettering with weights (Weight flick): a brand whose name is traced cannot play it.
    def needs_weights? = @weights

    def available?(brand) = !needs_weights? || !NavbarLogo.new(brand).traced?

    ALL = [
      new(:pop_slide, idea: "I1", title: "Pop and slide",
                      note: "A dot opens into the icon through a circle mask at the centre; the icon slides home and the name emerges from its edge."),
      new(:stack_build, idea: "I2", title: "Stack build",
                        note: "The icon drops in, the name rises letter by letter out of its baseline, and the small line tracks out to its spacing."),
      new(:match_cut, idea: "I16", title: "Match-cut build",
                      note: "A dot stretches into a line, flares, becomes the icon's seam; the icon opens from it and the name follows."),
      new(:shape_morph, idea: "I22", title: "Shape morph",
                        note: "A plain circle morphs into the icon's main shape; its other layers open from it and the name rises."),
      new(:tracking_breath, idea: "I23", title: "Tracking breath",
                            note: "The name draws in from a wide spread to its true spacing, the small line breathes out, and the icon rises last."),
      new(:dots_to_mark, idea: "I18", title: "Dots to mark",
                         note: "An accent dot splits into six that orbit and merge; the one dot flies into the icon, which opens around it."),
      new(:particle_resolve, idea: "I8", title: "Particle resolve",
                             note: "A shower of particles in the brand's accent sweeps in and settles on the icon's outline; the icon wipes in behind them."),
      new(:weight_flick, idea: "I17", title: "Weight flick", weights: true,
                         note: "The name rises in its thinnest weight, then flicks to the kit's weights on the beat. Only for lettering with weights.")
    ].freeze

    BY_KEY = ALL.index_by { |preset| preset.key.to_s }.freeze

    # The presets `brand` can play, in the Motion tab's order.
    def self.for(brand) = ALL.select { |preset| preset.available?(brand) }

    # The preset named `value` (a string or symbol), or an Error naming the ones there are.
    def self.find(value)
      BY_KEY.fetch(value.to_s) { raise Error, "unknown motion preset #{value.to_s.inspect[0, 40]}: expected one of #{BY_KEY.keys.join(', ')}" }
    end

    # The logo type named `value`, as a symbol, or an Error.
    def self.logo(value)
      LOGOS.keys.find { |type| type.to_s == value.to_s } or
        raise Error, "a motion plays on #{LOGOS.keys.join(' or ')}, not #{value.to_s.inspect[0, 40]}"
    end

    # A motion choice as the kit stores it, checked: { "preset" => "pop_slide", "logo" => "stacked" }. Anything else, a
    # preset the brand cannot play, or a key it does not know, is an Error.
    def self.check(brand, preset:, logo:)
      found = find(preset)
      raise Error, "brand #{brand}: #{found.title} needs lettering with weights, and its name is traced" unless found.available?(brand)

      { "preset" => found.key.to_s, "logo" => self.logo(logo).to_s }
    end

    # A stored motion choice (a Hash with exactly "preset" and "logo"), checked; an Error when it is anything else.
    def self.check_choice(brand, choice)
      unless choice.is_a?(Hash) && choice.keys.sort == %w[logo preset]
        raise Error, "a motion choice is a map of preset and logo, got #{choice.inspect[0, 80]}"
      end

      check(brand, preset: choice["preset"], logo: choice["logo"])
    end

    # The colour a preset's particles and dots are drawn in: the tone's `accent` where the brand's style names one,
    # else its most saturated palette colour (Studio's Violet, Industries' Forge Orange).
    def self.accent(brand, tone = :dark)
      style = NavbarLogo.styles.fetch(brand.to_s)
      named = style.dig("tones", tone.to_s, "accent")
      return named if named.is_a?(String) && NavbarLogo::HEX.match?(named)

      NavbarLogo.new(brand).palette.max_by { |hex| chroma(hex) }
    end

    # How far a colour is from grey: its largest channel less its smallest, 0 to 255.
    def self.chroma(hex)
      channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
      channels.max - channels.min
    end
    private_class_method :chroma
  end
end

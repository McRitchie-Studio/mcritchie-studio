# frozen_string_literal: true

module Appearances
  # FILE A GAME CHARACTER MODEL that bin/game-model built on the operator's Mac.
  #
  # The sheet was generated, face-gated and stitched locally (the face gate is
  # local by the operator's ruling, 2026-10-18) and uploaded to R2 before this
  # runs; only its object key arrives. This finds or makes the player's look for
  # that game ("Bears white · 2026 Week 6 at ATL"), makes its iced twin when an
  # iced sheet comes with it (Appearances::IcedTwin, the same twin a press of the
  # look page makes), and files each sheet as that look's character-sheet
  # Artifact, stamped with what made it.
  #
  # IDEMPOTENT ON THE KEY: a re-post of a sheet already filed returns the artifact
  # on file rather than a second row, so `bin/game-model file` may be re-run.
  class FileGameLook
    VARIANTS = %w[base iced].freeze
    GENERATOR = "game_model_layered"
    SOURCE = "Game model (layered, built locally by bin/game-model)"
    ENDPOINT = "https://api.openai.com/v1/images/edits"
    # The image model bin/game-model pins (GameModel::MODEL); stamped, not called.
    MODEL = "gpt-image-2.5-sunburst-2026-09-08"
    KEY_PREFIX = "character-sheets/game-models/"
    KEY_SHAPE = %r{\A#{Regexp.escape(KEY_PREFIX)}\d+/[a-z0-9-]+\.(?:jpg|png)\z}
    ROLE = "Character sheet"

    class Refused < StandardError
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    # `created` is true when this call filed at least one new sheet.
    Outcome = Struct.new(:look, :twin, :artifacts, :created, keyword_init: true)

    def self.call(params, storage: Studio::S3) = new(params, storage: storage).call

    def initialize(params, storage: Studio::S3)
      @params = params.to_h.stringify_keys
      @storage = storage
    end

    def call
      athlete = check!
      Appearance.transaction do
        look = look_for(athlete)
        twin = IcedTwin.create!(look) if iced?
        before = Artifact.count
        artifacts = sheets.map { |sheet| file(sheet, sheet["variant"] == "iced" ? twin : look) }
        Outcome.new(look: look, twin: twin, artifacts: artifacts, created: Artifact.count > before)
      end
    rescue IcedTwin::Refused => e
      raise Refused.new(e.message, "NO_ICED_TWIN")
    end

    # Every refusal, free and before any row is written; returns the athlete.
    # Public so the endpoint can answer a refusal without logging it as an error.
    def check!
      @check ||= begin
        check_sheets!
        athlete = Athlete.find_by(espn_id: @params["espn_id"].to_s.presence) ||
                  raise(Refused.new("no athlete has espn_id #{@params['espn_id'].inspect}", "NO_ATHLETE"))
        existing = existing_look(athlete)
        reason = existing && iced? && existing.iced_twin.nil? && IcedTwin.refusal(existing)
        raise Refused.new(reason, "NO_ICED_TWIN") if reason

        athlete
      end
    end

    private

    def sheets = Array(@params["sheets"]).map { |s| s.to_h.stringify_keys }

    def iced? = sheets.any? { |s| s["variant"] == "iced" }

    def check_sheets!
      raise Refused.new("descriptor is required (the uniform and game, e.g. \"Bears white · 2026 Week 6 at ATL\")", "INVALID") if descriptor.blank?
      raise Refused.new("sheets must be a non-empty list", "INVALID") if sheets.empty?
      raise Refused.new("one sheet per variant", "INVALID") if sheets.map { |s| s["variant"] }.uniq.size != sheets.size

      sheets.each do |sheet|
        raise Refused.new("sheet variant must be one of #{VARIANTS.join(', ')}", "INVALID") unless VARIANTS.include?(sheet["variant"])
        raise Refused.new("object_key must be #{KEY_PREFIX}<espn_id>/<name>.jpg", "INVALID_KEY") unless sheet["object_key"].to_s.match?(KEY_SHAPE)
        unless @storage.exists?(key: sheet["object_key"])
          raise Refused.new("#{sheet['object_key']} is not in the bucket; upload it first", "OBJECT_MISSING")
        end
      end
    end

    def descriptor = @params["descriptor"].to_s.strip

    def existing_look(athlete) = Appearance.live.find_by(person_slug: athlete.person_slug, descriptor: descriptor, iced: false)

    # The live look of that name, else a new one. A team only when it is on file:
    # a look may not name a team the teams table lacks (Appearance validation).
    def look_for(athlete)
      existing_look(athlete) ||
        Appearance.create!(person_slug: athlete.person_slug, descriptor: descriptor,
                           team_slug: (athlete.team_slug if Team.exists?(slug: athlete.team_slug)),
                           jersey_number: @params["jersey_number"].presence || athlete.jersey_number,
                           generation_notes: @params["generation_notes"].presence)
    end

    def file(sheet, look)
      url = @storage.url(key: sheet["object_key"])
      existing = Artifact.find_by(image_url: url, kind: "character_sheet")
      return existing if existing

      artifact = Artifact.create!(kind: "character_sheet", image_url: url, source: SOURCE, generator: GENERATOR,
                                  generator_endpoint: ENDPOINT, generator_version: MODEL,
                                  prompt: "Layered game character model (#{sheet['variant']}) for #{look.descriptor}")
      ArtifactSubject.create!(artifact_slug: artifact.slug, person_slug: look.person_slug,
                              appearance_slug: look.slug, ordinal: 1, role: ROLE)
      artifact
    end
  end
end

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
  # WHO THE SHEET IS OF. An athlete by `espn_id` (his look takes his team and
  # number), or, for someone with no athlete record (a head coach on the
  # sideline), a `person` by name and vocation: found by Person.find_by_name, or
  # created with that vocation inside the filing transaction. Exactly one of the
  # two. The R2 key's folder must name the same subject: the espn_id, or the
  # person's name slug.
  #
  # IDEMPOTENT ON THE KEY: a re-post of a sheet already filed returns the artifact
  # on file rather than a second row.
  class FileGameLook
    VARIANTS = %w[base iced].freeze
    GENERATOR = "game_model_layered"
    SOURCE = "Game model (layered, built locally by bin/game-model)"
    ENDPOINT = "https://api.openai.com/v1/images/edits"
    # The image model bin/game-model pins (GameModel::MODEL); stamped, not called.
    MODEL = "gpt-image-2.5-sunburst-2026-09-08"
    KEY_PREFIX = "character-sheets/game-models/"
    KEY_SHAPE = %r{\A#{Regexp.escape(KEY_PREFIX)}(?<folder>[a-z0-9-]+)/[a-z0-9-]+\.(?:jpg|png)\z}
    PERSON_KEYS = %w[first_name last_name vocation].freeze
    # A person filed by name may be any vocation but an athlete: an athlete
    # files by espn_id, so a namesake is never guessed at.
    PERSON_VOCATIONS = (Person::VOCATIONS - %w[athlete]).freeze

    # Who the sheet is of, as the look needs it. `person_slug` is nil until
    # #call creates a person filed by name who is not on file yet.
    Subject = Struct.new(:person_slug, :team_slug, :jersey_number, :folder, :new_person, keyword_init: true)
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
      subject = check!
      Appearance.transaction do
        subject.person_slug ||= create_person!(subject).slug
        look = look_for(subject)
        twin = IcedTwin.create!(look) if iced?
        before = Artifact.count
        artifacts = sheets.map { |sheet| file(sheet, sheet["variant"] == "iced" ? twin : look) }
        Outcome.new(look: look, twin: twin, artifacts: artifacts, created: Artifact.count > before)
      end
    rescue IcedTwin::Refused => e
      raise Refused.new(e.message, "NO_ICED_TWIN")
    end

    # Every refusal, free and before any row is written; returns the Subject.
    # Public so the endpoint can answer a refusal without logging it as an error.
    def check!
      @check ||= begin
        check_sheets!
        subject = resolve_subject
        check_folders!(subject)
        existing = subject.person_slug && existing_look(subject)
        reason = existing && iced? && existing.iced_twin.nil? && IcedTwin.refusal(existing)
        raise Refused.new(reason, "NO_ICED_TWIN") if reason

        subject
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
        raise Refused.new("object_key must be #{KEY_PREFIX}<espn_id or name-slug>/<name>.jpg", "INVALID_KEY") unless sheet["object_key"].to_s.match?(KEY_SHAPE)
        unless @storage.exists?(key: sheet["object_key"])
          raise Refused.new("#{sheet['object_key']} is not in the bucket; upload it first", "OBJECT_MISSING")
        end
      end
    end

    def descriptor = @params["descriptor"].to_s.strip

    def resolve_subject
      espn_id = @params["espn_id"].to_s.presence
      person = @params["person"]
      raise Refused.new("send espn_id (an athlete) or person (by name), not both", "INVALID") if espn_id && person
      return athlete_subject(espn_id) if espn_id
      return person_subject(person) if person

      raise Refused.new("send espn_id (an athlete) or person (by name)", "INVALID")
    end

    def athlete_subject(espn_id)
      athlete = Athlete.find_by(espn_id: espn_id) ||
                raise(Refused.new("no athlete has espn_id #{espn_id.inspect}", "NO_ATHLETE"))
      Subject.new(person_slug: athlete.person_slug, team_slug: athlete.team_slug,
                  jersey_number: athlete.jersey_number, folder: espn_id)
    end

    def person_subject(raw)
      fields = raw.respond_to?(:to_h) ? raw.to_h.stringify_keys : {}
      extra = fields.keys - PERSON_KEYS
      raise Refused.new("unpermitted person keys: #{extra.join(', ')}", "UNPERMITTED_KEYS") if extra.any?

      first, last, vocation = fields.values_at(*PERSON_KEYS).map { |v| v.to_s.strip }
      raise Refused.new("person needs first_name and last_name", "INVALID") if first.empty? || last.empty?
      unless PERSON_VOCATIONS.include?(vocation)
        raise Refused.new("person vocation must be one of #{PERSON_VOCATIONS.join(', ')} (an athlete files by espn_id)", "INVALID")
      end

      found = Person.find_by_name(first, last)
      # A namesake athlete is someone else: never file a by-name sheet on him.
      raise Refused.new("#{found.slug} is on file as an athlete; file an athlete by espn_id", "NAMESAKE") if found&.athlete?

      Subject.new(person_slug: found&.slug, team_slug: @params["team_slug"].presence, jersey_number: nil,
                  folder: "#{first} #{last}".parameterize, new_person: { first_name: first, last_name: last, vocation: vocation })
    end

    # A key filed under another subject's folder is refused: the folder is how
    # the bucket is read by person, so it must not lie.
    def check_folders!(subject)
      sheets.each do |sheet|
        folder = sheet["object_key"].to_s.match(KEY_SHAPE)[:folder]
        next if folder == subject.folder

        raise Refused.new("#{sheet['object_key']} is filed under #{folder}, not #{subject.folder}", "INVALID_KEY")
      end
    end

    # Runs inside the filing transaction, after every refusal.
    def create_person!(subject)
      attrs = subject.new_person
      flags = attrs[:vocation] == "coach" ? { coach: true } : { vocations: [attrs[:vocation]] }
      Person.find_or_create_by_name!(attrs[:first_name], attrs[:last_name], **flags)
    end

    def existing_look(subject) = Appearance.live.find_by(person_slug: subject.person_slug, descriptor: descriptor, iced: false)

    # The live look of that name, else a new one. A team only when it is on file:
    # a look may not name a team the teams table lacks (Appearance validation).
    def look_for(subject)
      existing_look(subject) ||
        Appearance.create!(person_slug: subject.person_slug, descriptor: descriptor,
                           team_slug: (subject.team_slug if Team.exists?(slug: subject.team_slug)),
                           jersey_number: @params["jersey_number"].presence || subject.jersey_number,
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

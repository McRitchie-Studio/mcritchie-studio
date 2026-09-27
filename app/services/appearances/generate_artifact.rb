module Appearances
  # GENERATE ONE CHARACTER SHEET OF ONE PERSON FROM ONE PHOTOGRAPH, and file it
  # with the stamp that says what made it.
  #
  # ONE CALL, ONE IMAGE, TEN PANELS — and that is a correction, not a shortcut.
  # This service first shipped generating ONE POSE per call from a five-entry pose
  # map, on the assumption that a sheet was five artifacts to be assembled. It is
  # not. The generator that actually holds a likeness produces the whole sheet as
  # a SINGLE image in a SINGLE call, and that is the reason it works: everything
  # in the frame is generated together, so the panels cannot drift apart from each
  # other. Five separate calls is precisely the shape that fails — measured on
  # fal-ai/flux-pulid, three calls at the same seed matched the reference 1 time
  # in 3, and a six-panel grid came back as six different men.
  #
  # SO A SHEET IS ONE ARTIFACT. Not five rows to stitch, not a parent with
  # children. One image, one row, one stamp.
  #
  # THIS IS THE ZERO-SHOT PATH AND IT HAS NO TRAINING STEP, which is why it exists
  # at all. Appearances::CreateCharacterReference asks Higgsfield to TRAIN a
  # character model from a photo set, and a training step is a stage that can
  # refuse: six measured attempts produced four refusals, always "We couldn't
  # prepare your photos for training". A zero-shot generator carries the likeness
  # at generation time from ONE face image, so there is no preparation stage to
  # fail — and one excellent front-facing headshot is exactly what we hold for
  # 2,043 athletes.
  #
  # IT ASKS THE REGISTRY FOR A CAPABILITY, NEVER FOR A VENDOR. `character_sheet`
  # is the requirement; which row satisfies it is config/image_generators.yml's
  # business. That seam earned itself within a day: the sheet generator moved from
  # fal to OpenAI and this file did not change except to ask for a stronger
  # capability.
  class GenerateArtifact
    # THE CAPABILITY THIS PATH REQUIRES, and it is deliberately the STRONG one.
    #
    # NOT `zero_shot_identity`, and not `single_portrait`. Both are true of rows
    # that return six different men on a grid — the portrait result and the sheet
    # result come apart, which is exactly why they are separate capabilities.
    # Asking for the weaker one here would route a sheet to a model measured to
    # fail at sheets.
    CAPABILITY = :character_sheet

    class NoIdentityPhoto < StandardError; end
    class NoGenerator < StandardError; end

    # WIDEST FIRST, AND `original` LEADS — a deliberate departure from
    # Appearances::ReferenceImages::HEADSHOT_VARIANTS (`%w[400 100]`).
    #
    # The two lists serve different vendors and the difference is the point. That
    # one feeds a TRAINING set, where a consistent modest crop across many photos
    # is fine. This feeds a generator reading ONE image, where every pixel of the
    # face is likeness it can carry.
    IDENTITY_VARIANTS = %w[original 400 100].freeze

    def self.call(appearance, **kwargs) = new(appearance, **kwargs).call

    def initialize(appearance, row: nil, prompt: nil, number: nil)
      @appearance = appearance
      @row = row
      @prompt = prompt
      @number = number
    end

    # ⚠ SPENDS MONEY. One sheet per press. Admin-gated at the call site.
    #
    # Returns the persisted Artifact. Raises rather than degrading, because the
    # one caller is an operator who pressed a button and is owed the reason —
    # AppearancesController wraps it in `rescue_and_log` so the reason also lands
    # in /admin/error_logs, where somebody reading it a day later can find it.
    def call
      raise NoGenerator, unconfigured_message if row.nil?
      raise NoIdentityPhoto, no_photo_message if identity_photo_url.blank?

      result = client.generate_and_wait(prompt: prompt, reference_urls: [identity_photo_url])
      raise ImageGeneration::GenerationFailed, "#{row.label} returned no image" unless result.any?

      # OUR COPY, BEFORE THE ROW EXISTS. The adapters answer in two different
      # shapes — fal a vendor CDN url, OpenAI a base64 data URI — and neither
      # belongs in the column. Storing first means a failed upload leaves no
      # artifact pointing at an object that was never written.
      stored_url = StoreGeneratedImage.call(result.primary_url, person_slug: @appearance.person_slug)
      persist(result, stored_url)
    end

    # THE ROW THAT WOULD SERVE, so the page can say WHICH generator is off rather
    # than only that generation is off.
    def self.preferred_row = ImageGeneration::Registry.preferred(CAPABILITY)
    def self.available? = ImageGeneration::Registry.for(CAPABILITY).present?

    def row = @row ||= ImageGeneration::Registry.for(CAPABILITY)

    # THE WHOLE SHEET'S INSTRUCTION. Built by Appearances::CharacterSheetPrompt,
    # which carries the operator-approved layout and the per-panel repetition rule
    # that layout depends on.
    def prompt
      @prompt.presence || CharacterSheetPrompt.call(@appearance, number: @number)
    end

    # THE ONE PHOTOGRAPH THE LIKENESS COMES FROM.
    #
    # ONE IS ENOUGH — measured, not assumed: five reference photos performed NO
    # BETTER than one. That is what keeps the image-search lane off the critical
    # path, because we already hold one good headshot for every athlete.
    #
    # READS THE STORED s3_key AND NEVER REBUILDS THE PATH. `Athlete#headshot_url`
    # resolves the ImageCache row and calls `ImageCache#url` on it; the sibling
    # `Athlete#headshot_key_prefix` is a WRITE-time builder. This matters right now
    # rather than in principle: Athletes::RekeyHeadshots is actively moving
    # athletes out of `headshots/nfl/free-agents/`, so a rebuilt path points at an
    # object that has already moved.
    #
    # ORDER: the cached headshot leads, the operator's typed URL follows — the
    # headshot is the one URL whose reachability we CONTROL and have measured,
    # while `reference_url` is free text that could point anywhere. Both are
    # fetchability-checked, because a private-range URL out of a form would be
    # asking somebody else's server to probe our network.
    def identity_photo_url
      return @identity_photo_url if defined?(@identity_photo_url)

      @identity_photo_url = [cached_headshot_url, @appearance&.reference_url]
                            .compact_blank
                            .find { |url| FetchableUrl.ok?(url) }
    end

    private

    def cached_headshot_url
      athlete = @appearance&.person&.athlete_profile
      return nil if athlete.nil?

      IDENTITY_VARIANTS.filter_map { |v| athlete.headshot_url(width: v) }.first
    end

    def client = ImageGeneration::Adapter.for(row).new(row)

    # THE STAMP. Every column answers a question the operator will ask of a library
    # holding images from more than one generator.
    #
    # `kind` IS character_sheet AND NOW MEANS IT. The value predates this work and
    # described a single generated image; one call now really does return a sheet.
    def persist(result, stored_url)
      artifact = Artifact.create!(
        kind: "character_sheet",
        image_url: stored_url,
        source: row.label,
        generator: row.key,
        generator_endpoint: row.endpoint,
        generator_version: row.provenance_version,
        seed: result.seed,
        prompt: prompt,
        cost_usd: result.cost_usd,
        billable_units: result.billable_units
      )
      ArtifactSubject.create!(
        artifact_slug: artifact.slug,
        person_slug: @appearance.person_slug,
        appearance_slug: @appearance.slug,
        ordinal: 1,
        role: "Character sheet"
      )
      artifact
    end

    def unconfigured_message
      preferred = self.class.preferred_row
      return "No image generator can produce a #{CAPABILITY}." if preferred.nil?

      preferred.unconfigured_message
    end

    def no_photo_message
      "#{@appearance.person&.full_name || 'This person'} has no cached headshot, so there is " \
        "no face to build a likeness from. Nothing was generated and nothing was spent."
    end
  end
end

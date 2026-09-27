module Appearances
  # GENERATE ONE CHARACTER SHEET OF ONE PERSON FROM THE PHOTOGRAPHS WE HAVE VETTED, and
  # file it with the stamp that says what made it.
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
  # at generation time from the face images it is given, so there is no preparation
  # stage to fail — and one excellent front-facing headshot is what we hold for
  # 2,043 athletes.
  #
  # AND IT NOW TAKES MORE THAN THAT ONE. The operator asked for it in these words on
  # 2026-09-27: *"while the character sheet is good, it would be better if we provided a
  # few headshots when submitting for the character model ... There needs to be a step for
  # finding and distilling reference images so we can provide more context on facial
  # structure and expressions to the model builder."*
  #
  # THE DISTILLING STEP ALREADY EXISTED AND FED THE WRONG GENERATOR. Appearances::
  # GatherReferencePhotos scouts and ranks, Appearances::ReferenceSet composes floor-first,
  # and both were wired only to the Higgsfield TRAINER — the path that refuses two thirds
  # of what it is given. This file now reads the same composed set, through
  # `ReferenceSet#generation_urls`, which is the sheet-side list: every vetted photograph,
  # our own mirrored copy preferred, capped.
  #
  # ⚠ ONE NARROWING REMAINS AND IT IS NOT IN THIS FILE. The registry row for the sheet
  # generator declares `reference_arity: one` (config/image_generators.yml), and
  # ImageGeneration::OpenAI honours that declaration — so today this hands over a list and
  # the adapter sends its first entry. The adapter is wired for the whole list; flipping
  # that one word is a CLAIM about the vendor's API that no measured call in this repo
  # supports, and no credential for it exists on the machine this was built on. It owes its
  # own task with a measurement in it.
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

      result = client.generate_and_wait(prompt: prompt, reference_urls: references)
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

    # THE PHOTOGRAPH THE LIKENESS IS GUARANTEED TO CARRY — our own cached headshot, or
    # the operator's URL when there is no headshot.
    #
    # STILL A SINGLE URL, AND STILL THE FLOOR. It is what `#references` leads with and it
    # is what the "nothing to generate from" refusal is judged on: a look with no cached
    # headshot and no typed URL has no face at all, and that is a state of the record the
    # operator is owed a sentence about rather than a vendor error.
    #
    # ⚠ THE "FIVE WERE NO BETTER THAN ONE" CLAIM USED TO BE THE JUSTIFICATION FOR
    # STOPPING HERE, AND IT CANNOT BE. The same sentence appears three times in this repo
    # attributed to three different paths — config/image_generators.yml credits this
    # Responses row, ImageGeneration::OpenAI credits /v1/images/edits (a different
    # endpoint it tells you never to use), and the 2026-09-27 operator relay credits the
    # Higgsfield TRAINING path. Three attributions of one measurement is no measurement,
    # so it is not load-bearing anywhere any more. Whether more references make a better
    # sheet on THIS path is UNMEASURED.
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

    # EVERY PHOTOGRAPH THIS SHEET IS BUILT FROM, floor first.
    #
    # THE FLOOR LEADS AND IS GUARANTEED TO BE THERE. `ReferenceSet#generation_urls` already
    # composes floor-first from the athlete's ImageCache row, but it resolves the headshot
    # through Appearances::ReferenceImages, whose variant list is `%w[400 100]` — this path
    # deliberately prefers `original` (IDENTITY_VARIANTS), because a zero-shot generator
    # reading one face carries every pixel of it. So `identity_photo_url` is prepended and
    # the set de-duplicates behind it.
    #
    # NEVER EMPTY WHEN #call PROCEEDS, because #call refuses first on a blank
    # `identity_photo_url` — which is the honest refusal: no face on file at all.
    def references
      ([identity_photo_url] + Array(ReferenceSet.new(@appearance).generation_urls))
        .compact_blank
        .uniq
        .first(ReferenceSet::GENERATION_LIMIT)
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

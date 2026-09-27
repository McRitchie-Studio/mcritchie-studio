module Appearances
  # GENERATE ONE IMAGE OF ONE PERSON FROM ONE PHOTOGRAPH, and file it with the
  # stamp that says what made it.
  #
  # THIS IS THE ZERO-SHOT PATH AND IT HAS NO TRAINING STEP, which is the whole
  # reason it exists. Appearances::CreateCharacterReference asks Higgsfield to
  # TRAIN a character model from a photo set, and a training step is a stage that
  # can refuse: six measured attempts on 2026-09-25/26 produced four refusals,
  # always "We couldn't prepare your photos for training", and the only two that
  # completed used a single tight ESPN headshot. A vision pass over the six
  # scouted Sutton photographs explained it — not one is a front-facing dominant
  # single face (one has ZERO faces behind a helmet, one has three, one is 15% of
  # frame, two are side profiles).
  #
  # A ZERO-SHOT ADAPTER CARRIES IDENTITY AT GENERATION TIME from ONE face image.
  # There is no preparation stage, so there is no preparation stage to fail — and
  # the one thing we have for all 2,043 athletes is exactly one excellent
  # front-facing headshot, in our own S3.
  #
  # IT ASKS THE REGISTRY FOR A CAPABILITY, NEVER FOR A VENDOR. `zero_shot_identity`
  # is the requirement; which row satisfies it is config/image_generators.yml's
  # business. That is the operator's "transition between generators as model
  # capacities change" made real: swapping the model is an edit to the YAML and
  # this file does not move.
  class GenerateArtifact
    CAPABILITY = :zero_shot_identity

    # THE SHEET THE OPERATOR ASKED FOR, in his words: "3 full body, head on, back,
    # side profile, plus examples of facial expressions."
    #
    # ORDERED BY HOW MUCH EACH ONE TELLS US, not by how the sheet will finally be
    # laid out, because the first entry is the one the spike buys. A face adapter
    # is strong on faces and weaker below the neck, so a PORTRAIT that works
    # proves the cheap half and leaves the deciding question untouched. The full
    # body shot is the one that can falsify the feature, so it goes first and it
    # is what DEFAULT_POSE points at.
    POSES = {
      "full_body_front" => {
        label: "Full body, head on",
        prompt: "full body photograph, standing facing the camera, head to toe in frame, " \
                "arms relaxed at the sides, photorealistic, sharp focus, even studio lighting, " \
                "plain neutral background"
      },
      "full_body_back" => {
        label: "Full body, from behind",
        prompt: "full body photograph from directly behind, standing, head to toe in frame, " \
                "back of the jersey visible, photorealistic, sharp focus, even studio lighting, " \
                "plain neutral background"
      },
      "side_profile" => {
        label: "Side profile",
        prompt: "full body photograph in side profile, standing, head to toe in frame, " \
                "photorealistic, sharp focus, even studio lighting, plain neutral background"
      },
      "head_on" => {
        label: "Portrait, head on",
        prompt: "head and shoulders portrait facing the camera, neutral expression, " \
                "photorealistic, sharp focus, even studio lighting, plain neutral background"
      },
      "expression_smile" => {
        label: "Expression, smiling",
        prompt: "head and shoulders portrait facing the camera, broad genuine smile, " \
                "photorealistic, sharp focus, even studio lighting, plain neutral background"
      }
    }.freeze

    DEFAULT_POSE = "full_body_front".freeze

    # PORTRAIT ASPECT. A character sheet is a standing human; a square or
    # landscape frame spends half its pixels on the neutral background either
    # side, and the full-body test needs the vertical.
    IMAGE_SIZE = "portrait_4_3".freeze

    class NoIdentityPhoto < StandardError; end
    class NoGenerator < StandardError; end

    # WIDEST FIRST, AND `original` LEADS — which is a deliberate departure from
    # Appearances::ReferenceImages::HEADSHOT_VARIANTS (`%w[400 100]`).
    #
    # The two lists serve different vendors and the difference is the point. That
    # one feeds a TRAINING set, where a consistent modest crop across many photos
    # is fine. This feeds a face adapter reading ONE image, where every pixel of
    # the face is identity it can carry — Sutton's `original` is 600x436 against
    # 400px, measured 2026-09-26. Changing the shared constant would have altered
    # the Higgsfield lane for no reason anybody asked for.
    IDENTITY_VARIANTS = %w[original 400 100].freeze

    def self.call(appearance, **kwargs) = new(appearance, **kwargs).call

    def initialize(appearance, pose: DEFAULT_POSE, seed: nil, row: nil)
      @appearance = appearance
      @pose = pose.to_s.presence || DEFAULT_POSE
      @seed = seed
      @row = row
    end

    # ⚠ SPENDS MONEY. Admin-gated at the call site.
    #
    # Returns the persisted Artifact. Raises rather than degrading, because the
    # one caller is an operator who pressed a button and is owed the reason —
    # AppearancesController wraps it in `rescue_and_log` so the reason also lands
    # in /admin/error_logs, where somebody reading it a day later can find it.
    def call
      raise NoGenerator, unconfigured_message if row.nil?
      raise NoIdentityPhoto, no_photo_message if identity_photo_url.blank?

      result = client.generate_and_wait(
        prompt: prompt,
        reference_urls: [identity_photo_url],
        seed: @seed,
        image_size: IMAGE_SIZE
      )
      raise ImageGeneration::Fal::GenerationError, "#{row.label} returned no image" unless result.any?

      persist(result)
    end

    # THE ROW THAT WOULD SERVE, so the page can say WHICH generator is off rather
    # than only that generation is off.
    def self.preferred_row = ImageGeneration::Registry.preferred(CAPABILITY)
    def self.available? = ImageGeneration::Registry.for(CAPABILITY).present?

    def row = @row ||= ImageGeneration::Registry.for(CAPABILITY)

    # WHAT THE MODEL IS ASKED FOR: the pose, then who the person is.
    #
    # POSE FIRST ON PURPOSE. The identity arrives through the reference image, not
    # through the words — the brief's job is to keep the uniform and the build
    # right, and leading with it buries the one instruction that decides whether
    # this is a full-body shot or another portrait.
    def prompt
      [pose_prompt, @appearance.generation_brief.presence].compact_blank.join(". ")
    end

    def pose_prompt = POSES.fetch(@pose, POSES.fetch(DEFAULT_POSE))[:prompt]
    def pose_label = POSES.fetch(@pose, POSES.fetch(DEFAULT_POSE))[:label]

    # THE ONE PHOTOGRAPH THE IDENTITY COMES FROM.
    #
    # READS THE STORED s3_key AND NEVER REBUILDS THE PATH. `Athlete#headshot_url`
    # resolves the ImageCache row and calls `ImageCache#url` on it; the sibling
    # `Athlete#headshot_key_prefix` is a WRITE-time builder. This matters right
    # now rather than in principle: Athletes::RekeyHeadshots is actively moving
    # athletes out of `headshots/nfl/free-agents/`, so a rebuilt path points at
    # an object that has already moved.
    #
    # ORDER: the cached headshot leads, the operator's typed URL follows — the
    # same ordering Appearances::ReferenceImages argues for, for the same reason.
    # The headshot is the one URL whose public reachability we CONTROL and have
    # measured; `reference_url` is free text that could point anywhere, including
    # somewhere the generator cannot reach.
    #
    # THE FALLBACK IS NOT DECORATION. A person with no cached ESPN headshot — a
    # coach, a new signing, anyone off the nflverse roster — has no other way into
    # this lane, and the column has a writer on the look form already.
    #
    # BOTH ARE FETCHABILITY-CHECKED, because we are handing a URL to somebody
    # else's server to fetch. Appearances::FetchableUrl holds that one opinion;
    # a private-range or localhost URL from a form would be asking a third party
    # to probe our network.
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

    # THE STAMP. Every column here answers a question the operator will ask of a
    # library holding images from more than one generator.
    def persist(result)
      artifact = Artifact.create!(
        kind: "character_sheet",
        image_url: result.primary_url,
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
        role: pose_label
      )
      artifact
    end

    def unconfigured_message
      preferred = self.class.preferred_row
      return "No image generator can do #{CAPABILITY}." if preferred.nil?

      preferred.unconfigured_message
    end

    def no_photo_message
      "#{@appearance.person&.full_name || 'This person'} has no cached headshot, so there is " \
        "no face to build an identity from. Nothing was generated and nothing was spent."
    end
  end
end

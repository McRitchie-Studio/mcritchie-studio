class Content
  class AssetsAgent
    # Higgsfield Soul — text-to-image generation
    # 9:16 vertical for TikTok (Higgsfield::Client::VERTICAL_9_16)

    # HOW HARD THE CHARACTER IDENTITY PULLS, on the API's 0..1 scale.
    #
    # 0.8 rather than 1.0: these are ACTION shots described by a scene prompt —
    # a quarterback mid-throw, a camera behind the player — and a reference
    # pinned at full strength fights the pose for control of the frame. Leaving
    # a fifth of the budget to the prompt is the starting point, not a measured
    # optimum; nobody has compared outputs, because doing so costs a generation
    # per value.
    CHARACTER_REFERENCE_STRENGTH = 0.8

    def self.assets_latest
      content = Content.where(stage: "script").order(position: :desc, created_at: :desc).first
      raise "No script content to generate assets" unless content

      new(content).call
    end

    def initialize(content)
      @content = content
      @client = Higgsfield::Client.new
    end

    def call
      raise "Content must be in script stage" unless @content.stage == "script"

      scene_assets = generate_scene_assets
      Content::Assets.new(@content).call(scene_assets: scene_assets)
      @content
    end

    private

    def generate_scene_assets
      scenes = @content.scenes || []
      # Select 2-5 key scenes for image generation
      key_scenes = scenes.first(5)

      key_scenes.map do |scene|
        prompt = build_image_prompt(scene)
        puts "  Generating image for scene #{scene["number"]}: #{prompt.truncate(100)}"

        # 9:16 for TikTok and Reels. The literal "1024x1792" that used to sit
        # here is no longer a size the API accepts.
        image_url = @client.generate_image_and_wait(
          prompt: prompt,
          width_and_height: Higgsfield::Client::VERTICAL_9_16,
          quality: "1080p",
          enhance_prompt: true,
          **character_reference
        )

        puts "    -> #{image_url.truncate(80)}"

        {
          "scene_number" => scene["number"],
          "prompt_used" => prompt,
          "image_url" => image_url
        }
      end
    end

    def build_image_prompt(scene)
      parts = []
      parts << "Cinematic sports photograph, third-person camera behind player, NFL football game"
      parts << scene["description"] if scene["description"]
      parts << "Camera: #{scene["camera"]}" if scene["camera"]

      # HOW THE PERSON LOOKS — from their recorded LOOK when they have one.
      #
      # This used to re-derive build/skin tone/hair from the Athlete record
      # inline, which was Appearance#generation_brief's own body written a second
      # time. #generation_brief had ZERO callers anywhere in the app (measured
      # 2026-09-24: two test references and nothing else), so the richer of the
      # two — the one that also carries the look's descriptor and the operator's
      # free-text generation notes — was the one nothing sent to Higgsfield.
      # Wiring it here is what makes a Jim Carrey or a George Bush in the cast
      # describable at all: neither has an Athlete record, so the old block
      # produced nothing for them.
      #
      # THE ATHLETE FALLBACK STAYS, and is not redundant with it. A person with
      # an Athlete record but no look on file is the ordinary state — a look is
      # only filed when someone attaches an image or names a colorway — and
      # dropping to `nil` there would have deleted a description the prompt
      # carries today.
      brief = appearance&.generation_brief.presence || athlete&.physical_brief
      parts << brief if brief.present?

      # Team uniforms
      if @content.source_news&.primary_team_slug
        team = Team.find_by(slug: @content.source_news.primary_team_slug)
        parts << "Home uniform colors: #{team.color_primary}/#{team.color_secondary}" if team
      end

      if @content.rival_team
        parts << "Opponent uniform colors: #{@content.rival_team.color_primary}/#{@content.rival_team.color_secondary}"
      end

      parts << "Vertical 9:16 aspect ratio, photorealistic, dramatic lighting"
      parts.join(". ")
    end

    # PIN THE SHOT TO THIS PERSON'S FACE — the whole point of the lane.
    #
    # Returns the two keyword arguments, or an EMPTY HASH, which is why the call
    # site splats it: an unpinned generation must send neither key rather than
    # sending nulls.
    #
    # READINESS IS CHECKED, NOT ASSUMED. An identity is minted `not_ready` and
    # takes a minute or so to reach `completed`, so a generation fired straight
    # after a create would name an identity that is still training. Falling back
    # to an unpinned shot is the right degradation: the picture is still made,
    # it just does not hold the likeness — whereas raising here would strand a
    # whole content run on a reference that will be ready shortly.
    def character_reference
      return {} unless appearance&.higgsfield_reference_ready?

      {
        custom_reference_id: appearance.higgsfield_reference_id,
        custom_reference_strength: CHARACTER_REFERENCE_STRENGTH
      }
    end

    # The look this content's subject is being drawn in. `defined?` rather than
    # `||=` because nil is the common answer — most people have no look on file —
    # and `||=` would re-run the lookup for every scene in the run.
    def appearance
      return @appearance if defined?(@appearance)

      @appearance = person&.default_appearance
    end

    def athlete
      return @athlete if defined?(@athlete)

      @athlete = person&.athlete_profile
    end

    def person
      return @person if defined?(@person)

      slug = @content.source_news&.primary_person_slug
      @person = slug.present? ? Person.find_by(slug: slug) : nil
    end
  end
end

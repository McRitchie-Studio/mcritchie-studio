class Content
  class AssetsAgent
    # Higgsfield Soul — text-to-image generation
    # 9:16 vertical for TikTok (Higgsfield::Client::VERTICAL_9_16)

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
          enhance_prompt: true
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

      # Player appearance
      if @content.source_news&.primary_person_slug
        athlete = Athlete.joins(:person).find_by(people: { slug: @content.source_news.primary_person_slug })
        if athlete
          parts << "Player build: #{athlete.build}" if athlete.build.present?
          parts << "Player skin tone: #{athlete.skin_tone}" if athlete.skin_tone.present?
          parts << "Player hair: #{athlete.hair_description}" if athlete.hair_description.present?
        end
      end

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
  end
end

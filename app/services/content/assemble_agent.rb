class Content
  class AssembleAgent
    # Higgsfield image-to-video generation (Kling 2.5 via Higgsfield::Client).
    # Takes scene images and generates cinematic motion video.
    #
    # The "DoP" model this used to name was the retired platform.higgsfield.ai
    # surface; the model is part of the request PATH now, so the default is
    # selected by the client rather than named here.

    def self.assemble_latest
      content = Content.where(stage: "assets").order(position: :desc, created_at: :desc).first
      raise "No assets content to assemble" unless content

      new(content).call
    end

    def initialize(content)
      @content = content
      @client = Higgsfield::Client.new
    end

    def call
      raise "Content must be in assets stage" unless @content.stage == "assets"

      video_url = generate_video
      Content::Assemble.new(@content).call(
        final_video_url: video_url,
        music_track: nil,
        text_overlays: [],
        logo_overlay: false
      )
      @content
    end

    private

    def generate_video
      scene_assets = @content.scene_assets || []
      raise "No scene assets to assemble into video" if scene_assets.empty?

      image_urls = scene_assets.map { |a| a["image_url"] }.compact
      raise "No image URLs in scene assets" if image_urls.empty?

      # Use the first scene image as the starting frame.
      #
      # KNOWN GAP, not a design: AssetsAgent generates an image per scene (up to
      # five, each one paid for) and this discards all but the first, so ~80% of
      # the image spend is thrown away on every run — on the very pool whose
      # emptiness blocks the feature. Multi-scene stitching is its own task.
      # Clip length is whatever the model's default is; no duration is passed.
      primary_image = image_urls.first
      prompt = build_video_prompt

      puts "  Generating video from #{image_urls.size} scene images"
      puts "  Primary image: #{primary_image.truncate(80)}"
      puts "  Prompt: #{prompt.truncate(120)}"

      # No `model:` — "dop-turbo" named the retired body-field model and the
      # client now REFUSES an unknown name rather than ignoring it. nil takes
      # the current default path (kling-pro).
      video_url = @client.generate_video_and_wait(
        image_url: primary_image,
        prompt: prompt
      )

      puts "  -> Video: #{video_url.truncate(80)}"
      video_url
    end

    def build_video_prompt
      parts = []
      parts << "Cinematic NFL football highlight, smooth camera movement"

      # Use the script narrative for motion context
      if @content.script_text.present?
        parts << @content.script_text.truncate(200)
      end

      # Player/team context
      if @content.source_news&.primary_person.present?
        parts << "Featuring #{@content.source_news.primary_person}"
      end

      parts << "Dynamic sports cinematography, dramatic slow motion, broadcast quality"
      parts.join(". ")
    end
  end
end

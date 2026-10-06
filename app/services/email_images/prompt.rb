# frozen_string_literal: true

module EmailImages
  # THE INSTRUCTION FOR ONE EMAIL HEADER, built from the brief and its brand kit.
  #
  # Deterministic: the same brief and kit always give the same words, so a
  # candidate's stored prompt says exactly what was asked. The brand kit owns
  # the look; the brief owns the words and any notes.
  #
  # TEXT MODE DECIDES ONE SENTENCE. `baked` asks the model to draw the headline
  # (the house look of Turf's existing banners); `none` forbids any lettering,
  # because the engine's layered banner will set the headline as live HTML over
  # the art and baked words would collide with it.
  class Prompt
    def self.call(brief) = new(brief).call

    def initialize(brief)
      @brief = brief
      @kit = brief.kit
      @preset = brief.preset_config
    end

    def call
      [
        "Create a wide #{orientation} email header banner for #{@kit.label}.",
        references_sentence,
        "Style: #{@kit.style}",
        "Brand palette: #{palette_words}.",
        text_sentence,
        notes_sentence,
        "Compose for a #{@preset.width}x#{@preset.height} crop: keep the important subject " \
          "and any lettering inside the centre #{safe_area}, nothing important near the edges.",
        "Never: #{@kit.negative}"
      ].compact_blank.join("\n\n")
    end

    private

    def orientation = "landscape"

    # What the images it is shown are for, in the order the adapter sends them.
    def references_sentence
      roles = @kit.references.map(&:role)
      parts = []
      parts << "The first reference image is the brand's mascot; draw that same character." if roles.first == "mascot"
      parts << "The first reference image is the brand's logo mark; feature it faithfully." if roles.first == "logo"
      if roles.include?("style")
        parts << "Another reference is an existing header from this brand: match its colours, " \
                 "lighting and illustration style, but do not copy its words or layout exactly."
      end
      parts.join(" ")
    end

    def palette_words = @kit.palette.map { |name, hex| "#{name} #{hex}" }.join(", ")

    def text_sentence
      if @brief.text_mode == "baked"
        line = %(Draw the headline "#{@brief.headline}" in a bold geometric sans-serif (like #{@kit.font}), ) +
               "large, white with one word highlighted in the brand's highlight green or primary colour, " \
               "on the left half, spelled exactly as given. No other words anywhere."
        @brief.subtext.present? ? "#{line} Under it, smaller: \"#{@brief.subtext}\"." : line
      else
        "Draw NO text, letters, numbers or words anywhere in the image; leave the left half calm " \
          "and dark enough for white text to be laid over it later."
      end
    end

    def notes_sentence
      notes = @brief.prompt_notes.to_s.squish
      notes.present? ? "Notes for this email: #{notes}" : nil
    end

    # 1536x1024 scaled to cover 1200x600 is 1200x800, so EmailImages::Crop cuts
    # 100 px (an eighth of the height) from the top and the bottom. Said in words
    # the model can use.
    def safe_area = "band covering the middle three quarters of the height"
  end
end

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
  #
  # A ROUND'S DIRECTION IS RECORDED IN THE PROMPT ITSELF (piece 6). The round
  # number and the operator's notes for that round ride as one fixed line, so
  # the candidate's stored `prompt` column says exactly what the model was told
  # AND which round asked for it, with no new column: `Prompt.round_of` reads
  # the line back for `bin/email-image show`. Nothing else may write a line that
  # starts "Round <n>".
  class Prompt
    ROUND_WITH_NOTES = /^Round (?<round>\d+) direction: (?<notes>.+)$/
    ROUND_ONLY = /^Round (?<round>\d+)\.$/
    MAX_NOTES = 1_000

    RoundLine = Struct.new(:round, :notes, keyword_init: true)

    def self.call(brief, **kwargs) = new(brief, **kwargs).call

    # The round and notes a stored prompt was built with; nil round for a
    # prompt written before rounds were recorded.
    def self.round_of(prompt)
      text = prompt.to_s
      if (m = ROUND_WITH_NOTES.match(text))
        RoundLine.new(round: m[:round].to_i, notes: m[:notes])
      elsif (m = ROUND_ONLY.match(text))
        RoundLine.new(round: m[:round].to_i, notes: nil)
      else
        RoundLine.new(round: nil, notes: nil)
      end
    end

    def self.clean_notes(notes) = notes.to_s.squish.truncate(MAX_NOTES).presence

    # `references:` is the list the round sends, in order (EmailImages::Generate
    # passes the one it cut for its row); left out, it is the kit's default cut.
    def initialize(brief, round: nil, round_notes: nil, references: nil)
      @brief = brief
      @kit = brief.kit
      @references = references || @kit.generator_references
      @preset = brief.preset_config
      @round = round
      @round_notes = self.class.clean_notes(round_notes)
    end

    def call
      [
        "Create a wide #{orientation} email header banner for #{@kit.label}.",
        references_sentence,
        "Style: #{@kit.style}",
        "Brand palette: #{palette_words}.",
        text_sentence,
        notes_sentence,
        round_line,
        "Compose for a #{@preset.width}x#{@preset.height} crop: keep the important subject " \
          "and any lettering inside the centre #{safe_area}, nothing important near the edges.",
        "Never: #{@kit.negative}"
      ].compact_blank.join("\n\n")
    end

    private

    def orientation = "landscape"

    # What the images it is shown are for, in the order the adapter sends them.
    # An uploaded reference is named by its position, role and label, with the
    # admin's note on how to use it ("use this pose").
    def references_sentence
      roles = @references.map(&:role)
      parts = []
      parts << "The first reference image is the brand's mascot; draw that same character." if roles.first == "mascot"
      parts << "The first reference image is the brand's logo mark; feature it faithfully." if roles.first == "logo"
      if @references.any? { |ref| ref.yaml? && ref.role == "style" }
        parts << "Another reference is an existing header from this brand: match its colours, " \
                 "lighting and illustration style, but do not copy its words or layout exactly."
      end
      @references.each_with_index do |ref, i|
        next unless ref.upload?

        line = %(Reference image #{i + 1} is a #{ref.role} reference, "#{ref.label.to_s.squish}")
        parts << (ref.note.present? ? "#{line}: #{ref.note.to_s.squish}." : "#{line}.")
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

    # This round's direction from the operator, after the brief's standing notes
    # so the newer word reads last. Without a round number there is no line.
    def round_line
      return nil if @round.blank?

      @round_notes ? "Round #{@round} direction: #{@round_notes}" : "Round #{@round}."
    end

    # 1536x1024 scaled to cover 1200x600 is 1200x800, so EmailImages::Crop cuts
    # 100 px (an eighth of the height) from the top and the bottom. Said in words
    # the model can use.
    def safe_area = "band covering the middle three quarters of the height"
  end
end

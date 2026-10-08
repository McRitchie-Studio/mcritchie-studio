# frozen_string_literal: true

module EmailImages
  # WHAT THE GENERATOR PAGE SHOWS FOR ONE KIT (/email_images/generator/:kit,
  # task email-image-generator-page): the character model, a few example
  # headers, and the copy-paste prompt's fixed parts. Read-only; no generator
  # is ever called from here.
  class GeneratorPage
    MAX_EXAMPLES = 4

    # A reference photo titled like this is the character's approved canonical
    # sheet ("Canonical sheet v3 (white jersey, pads, no helmet) - approved by
    # Alex 2026-10-07"). The newest one wins.
    CANONICAL_TITLE = /\Acanonical sheet/i

    # One picture on the page, whatever table it came from.
    Image = Struct.new(:url, :label, :source, keyword_init: true)

    attr_reader :kit

    def initialize(kit)
      @kit = kit
    end

    def character = defined?(@character) ? @character : (@character = Character.featured_for(kit.key))
    def character? = character.present?

    # The character's default look, else its oldest live look.
    def look
      return nil unless character?

      @look ||= begin
        looks = character.appearances.live.order(:created_at, :id).to_a
        looks.find { |l| l.slug == character.default_appearance_slug } || looks.first
      end
    end

    # THE MODEL IMAGE, in the order Alex asked for: a reference titled
    # "Canonical sheet…" (newest first), else the newest approved character
    # sheet of the character, else the look's first reference. Nil when the
    # character has nothing drawn yet.
    def model_image
      return nil unless character?

      @model_image ||= canonical_reference || approved_sheet || first_reference
    end

    def prompt_template = GeneratorPrompt.template_for(kit_key: kit.key, character_name: character&.name)
    def prompt = GeneratorPrompt.call(kit_key: kit.key, character_name: character&.name)
    def cli_hint = GeneratorPrompt.cli_hint(kit.key)

    # UP TO FOUR EXAMPLE HEADERS: the brand's approved email headers, newest
    # approval first, then the kit's style anchor(s), each labelled.
    def examples
      @examples ||= (approved_headers + style_anchors).first(MAX_EXAMPLES)
    end

    private

    def look_references
      return [] if look.nil?

      @look_references ||= look.reference_photos.chosen.gallery_order.to_a
    end

    def canonical_reference
      photo = look_references.select { |p| p.title.to_s.match?(CANONICAL_TITLE) }
                             .max_by { |p| [p.created_at, p.id] }
      photo && Image.new(url: photo.image_url, label: photo.title, source: "reference photo")
    end

    def approved_sheet
      sheet = Artifact.live.approved.where(kind: "character_sheet").joins(:subjects)
                      .where(artifact_subjects: { character_slug: character.slug })
                      .order(created_at: :desc, id: :desc).first
      sheet && Image.new(url: sheet.image_url, label: "Approved character sheet", source: "artifact #{sheet.slug}")
    end

    def first_reference
      photo = look_references.first
      photo && Image.new(url: photo.image_url, label: photo.title.presence || look.descriptor,
                         source: "reference photo")
    end

    def approved_headers
      briefs = EmailImageBrief.where(brand_kit: kit.key).where.not(approved_artifact_slug: nil).index_by(&:approved_artifact_slug)
      return [] if briefs.empty?

      Artifact.live.approved.where(kind: "email_header", slug: briefs.keys).order(approved_at: :desc, id: :desc)
              .first(MAX_EXAMPLES).map do |artifact|
        brief = briefs.fetch(artifact.slug)
        Image.new(url: artifact.image_url, label: "#{brief.catalog_key}: “#{brief.headline}”",
                  source: "approved header")
      end
    end

    def style_anchors
      kit.references.select { |ref| ref.role == "style" }.map do |ref|
        Image.new(url: ref.display_url, label: "Style anchor (#{ref.label})", source: "kit style anchor")
      end
    end
  end
end

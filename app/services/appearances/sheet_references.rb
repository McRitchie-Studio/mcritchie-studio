# frozen_string_literal: true

module Appearances
  # EVERY IMAGE ONE PLAYER-SHEET BUILD SENDS, WITH ITS ROLE, IN A FIXED ORDER (task
  # player-sheet-uniform-and-build):
  #
  #   1. IDENTITY ANCHOR — the face (Appearances::GenerateArtifact#references).
  #   2. UNIFORM REFERENCE — up to AppearanceUniformPhoto::CHOSEN_LIMIT game photos.
  #   3. BODY BUILD REFERENCE — the look's archetype image, when it has one.
  #
  # THE ORDER IS THE CONTRACT WITH THE PROMPT. The image blocks ride first and the
  # text last (ImageGeneration::OpenAI#request_body), and Appearances::
  # CharacterSheetPrompt names each image by its position ("Image 2: UNIFORM
  # REFERENCE"), so the count of faces actually SENT decides every later number. That
  # count is the row's `reference_arity` rule applied here exactly as the adapter
  # applies it (`one` sends the first face only); the uniform and body images are
  # never faces, so the arity does not govern them and they ride in full.
  class SheetReferences
    UNIFORM_PHOTO = "uniform photo".freeze
    BODY_ARCHETYPE = "body archetype".freeze

    attr_reader :identity_urls

    # `identity_urls`: the faces OFFERED, floor first. `row`: the generator, whose
    # arity says how many of them are sent.
    def initialize(appearance, identity_urls:, row:)
      @appearance = appearance
      @identity_urls = Array(identity_urls)
      @row = row
    end

    # A STAND-IN FOR A PROMPT READ WITHOUT A BUILD: one face, nothing else attached.
    def self.prompt_only(appearance) = new(appearance, identity_urls: [], row: nil).tap(&:prompt_only!)

    def prompt_only!
      @prompt_only = true
      self
    end

    def identity_count
      return 1 if @prompt_only
      return @identity_urls.first(1).length if @row&.reference_arity.to_s == "one"

      @identity_urls.length
    end

    # OUR HOSTED COPIES ONLY (Appearances::MirrorUniformPhoto, made at the pick). A
    # chosen photo with no copy is never sent: the search hit is somebody else's
    # server, and downloading it here would re-resolve its host unpinned and fail the
    # build after the claim on a hotlink refusal. Still fetch-checked, like every URL
    # the adapter downloads.
    def uniform_urls
      return [] if @prompt_only

      @uniform_urls ||= @appearance.uniform_source.uniform_photos.chosen
                                   .first(AppearanceUniformPhoto::CHOSEN_LIMIT).map(&:hosted_url).compact_blank
                                   .select { |url| FetchableUrl.ok_for?(url, look: @appearance.slug, what: UNIFORM_PHOTO) }
    end

    def archetype = @archetype ||= @appearance.body_archetype

    def body_url
      return nil if @prompt_only
      return @body_url if defined?(@body_url)

      url = archetype&.image_url
      @body_url = url.present? && FetchableUrl.ok_for?(url, look: @appearance.slug, what: BODY_ARCHETYPE) ? url : nil
    end

    # The images that are not faces, in order: uniform, then body.
    def supporting_urls = uniform_urls + [body_url].compact

    # How many images the request carries in all.
    def total_count = identity_count + supporting_urls.length

    # [first, last, role] per role present, 1-based, in sending order.
    def roles
      spans = []
      cursor = 1
      [[:identity, identity_count], [:uniform, uniform_urls.length], [:body, body_url ? 1 : 0]].each do |role, count|
        next if count.zero?

        spans << [cursor, cursor + count - 1, role]
        cursor += count
      end
      spans
    end
  end
end

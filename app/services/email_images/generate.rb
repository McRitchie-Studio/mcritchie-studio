# frozen_string_literal: true

module EmailImages
  # ONE ROUND OF HEADER CANDIDATES FOR ONE BRIEF: N paid calls, each cropped to
  # the preset, stored in our bucket, and filed as an `email_header` Artifact.
  #
  # The shape is Appearances::GenerateArtifact's: ask the registry for a
  # CAPABILITY (`email_header`), refuse for free before any spend (`check!`),
  # store our copy before the row exists (Appearances::StoreGeneratedImage, the
  # "our copy, our bucket" rule), then stamp generator, version, prompt,
  # billable units and cost (nil = unpriced, never free).
  #
  # ⚠ SPENDS MONEY. Runs only inside EmailImages::Build, which claims the brief
  # first so a round runs once; the job is admin-started and never retried.
  class Generate
    CAPABILITY = :email_header
    STORAGE_PREFIX = "email_images"

    class NoGenerator < StandardError; end
    class RoundsExhausted < StandardError; end
    class MissingReference < StandardError; end
    # A paid image that will not fit the email byte budget even after a second,
    # harder squeeze. Not a free refusal: the image was bought, so Build logs it.
    class OverBudget < StandardError; end

    def self.call(brief, **kwargs) = new(brief, **kwargs).call

    def initialize(brief, row: nil, count: nil, round: nil, notes: nil)
      @brief = brief
      @row = row
      @round = round
      @notes = notes
      @count = (count || EmailImages::BrandKit.candidates_per_round).to_i.clamp(1, EmailImages::BrandKit.candidates_per_round)
    end

    # THE FREE REFUSALS, raised in the request before anything is claimed.
    def check!
      raise NoGenerator, unconfigured_message if row.nil?
      if @brief.rounds_exhausted?
        raise RoundsExhausted, "This brief has used all #{@brief.max_rounds} rounds. Change the brief " \
                               "(headline, notes) or raise its round limit; nothing was spent."
      end
      missing = @brief.kit.references.reject(&:exists?)
      raise MissingReference, "Brand kit reference missing: #{missing.map(&:path).join(', ')}" if missing.any?
    end

    # Returns the persisted candidates. A failure after the first image keeps
    # the ones already paid for and raises with the reason.
    def call
      Array.new(@count) { generate_one }
    end

    def row
      @row ||= if @brief.generator_key.present?
                 found = ImageGeneration::Registry.find(@brief.generator_key)
                 found if found&.capable_of?(CAPABILITY) && found.available?
               else
                 ImageGeneration::Registry.for(CAPABILITY)
               end
    end

    def prompt = @prompt ||= EmailImages::Prompt.call(@brief, round: @round, round_notes: @notes)

    private

    def generate_one
      result = client.generate_and_wait(prompt: prompt, reference_urls: @brief.kit.reference_data_uris,
                                        image_size: generate_size, num_images: 1)
      raise ImageGeneration::GenerationFailed, "#{row.label} returned no image" unless result.any?

      cropped = fit_budget(result.primary_url)
      stored_url = Appearances::StoreGeneratedImage.call(cropped.data_uri, prefix: STORAGE_PREFIX,
                                                                           subject: @brief.storage_subject)
      Artifact.create!(
        kind: "email_header",
        brief_slug: @brief.slug,
        image_url: stored_url,
        source: row.label,
        generator: row.key,
        generator_endpoint: row.endpoint,
        generator_version: row.provenance_version,
        seed: result.seed,
        prompt: prompt,
        billable_units: result.billable_units,
        cost_usd: result.cost_usd
      )
    end

    # THE EMAIL BYTE BUDGET IS HARD (about 300 KB). Crop already steps a JPG
    # down to quality 60 and quantizes a PNG; when that is still over, squeeze
    # once more (JPG to quality 40, PNG to 64 colours), and if even that will
    # not fit, refuse to store it rather than file a header no inbox should load.
    def fit_budget(source)
      preset = @brief.preset_config
      crop = ->(**opts) { EmailImages::Crop.call(source, width: preset.width, height: preset.height,
                                                         format: @brief.image_format, **opts) }
      cropped = crop.call
      return cropped unless cropped.over_budget?

      cropped = crop.call(squeeze: true)
      return cropped unless cropped.over_budget?

      raise OverBudget, "the generated header is #{cropped.bytesize} bytes after squeezing, over the " \
                        "#{EmailImages::BrandKit.max_bytes}-byte email budget; it was not stored"
    end

    def generate_size = @brief.preset_config&.generate_size.presence || row.image_size

    def client = ImageGeneration::Adapter.for(row).new(row)

    def unconfigured_message
      if @brief.generator_key.present?
        found = ImageGeneration::Registry.find(@brief.generator_key)
        return "No generator row #{@brief.generator_key.inspect} can make an email header." unless found&.capable_of?(CAPABILITY)

        return found.unconfigured_message
      end
      preferred = ImageGeneration::Registry.preferred(CAPABILITY)
      preferred ? preferred.unconfigured_message : "No image generator can produce an #{CAPABILITY}."
    end
  end
end

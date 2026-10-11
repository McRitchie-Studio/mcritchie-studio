# frozen_string_literal: true

module BodyArchetypes
  # (RE)GENERATE ONE BODY ARCHETYPE'S IMAGE — ⚠ ONE PAID GPT-5 IMAGE PER CALL, and
  # only ever on the operator's click (BodyArchetypesController#generate).
  #
  # THE SAME GENERATOR AS THE SHEET, asked for the same capability
  # (Appearances::GenerateArtifact::CAPABILITY), so the archetype is drawn by the
  # model that will read it back. Text only: there is no face to show it, and the
  # point of the image is that it carries none.
  #
  # OFF THE REQUEST, LIKE A SHEET BUILD: a generation takes minutes and Heroku cuts a
  # request at 30 s. `start!` claims the row with one conditional update (two presses
  # cannot both win) and enqueues BodyArchetypeGenerateJob; `run` takes the claim
  # before the paid call, so a re-run job spends nothing.
  class Generate
    class Refused < StandardError; end

    STARTED_NOTICE = "Generating the archetype image in the background (one paid image); it takes about " \
                     "two minutes. Reload the page to see it."
    STORAGE_PREFIX = "body-archetypes"

    # THE PROMPT. Two full-body figures, front and back, in plain padded practice
    # gear: what the sheet needs from it is a silhouette, so everything that could be
    # mistaken for an identity or a team is refused by name.
    def self.prompt_for(archetype)
      [
        "Generate a body-build reference image of #{archetype.description}, as a single image showing TWO " \
        "full body standing figures of the SAME body side by side, head to cleats fully in frame: LEFT facing " \
        "the camera, RIGHT facing away showing his back.",
        "He wears plain padded football practice gear: a plain grey practice jersey worn OVER bulky shoulder " \
        "pads that create a broad squared padded silhouette at the shoulders, plain grey practice pants with " \
        "thigh and knee pads, plain black cleats. NO helmet.",
        "NO face detail: the face is softly out of focus and unrecognisable, with no distinguishing features. " \
        "NO team marks: no logos, no numbers, no names, no stripes, no lettering anywhere.",
        "Identical neutral grey seamless studio background and even NFL team-photo-day lighting. " \
        "Photorealistic, sharp focus on the body's build and proportions."
      ].join("\n\n")
    end

    def self.row = ImageGeneration::Registry.for(Appearances::GenerateArtifact::CAPABILITY)

    # THE FREE REFUSALS, before anything is claimed or spent.
    def self.check!(archetype)
      row = self.row
      if row.nil?
        preferred = Appearances::GenerateArtifact.preferred_row
        raise Refused, preferred ? preferred.unconfigured_message : "No image generator can draw an archetype."
      end
      return if row.adapter.to_s == "openai"

      raise Refused, "#{row.label} cannot generate from a prompt alone, so no archetype image was made."
    end

    def self.start!(archetype)
      check!(archetype)
      started_at = claim!(archetype)
      BodyArchetypeGenerateJob.perform_later(archetype.slug, started_at.iso8601(6))
      started_at
    end

    def self.claim!(archetype)
      now = Time.current.floor(6)
      claimed = BodyArchetype.where(id: archetype.id)
                             .where("generation_state IS DISTINCT FROM ? OR generation_started_at IS NULL " \
                                    "OR generation_started_at < ?", BodyArchetype::BUILDING,
                                    now - BodyArchetype::STALE_AFTER)
                             .update_all(generation_state: BodyArchetype::BUILDING, generation_started_at: now,
                                         generation_error: nil, updated_at: now)
      raise Refused, "#{archetype.name} is already generating. Nothing new was started or spent." if claimed.zero?

      now
    end

    # Runs in the job. Returns without spending when the claim is no longer this run's.
    #
    # THE TAKE RESTAMPS THE CLAIM WITH NOW, as Appearances::SheetBuild.take does, so the
    # STALE_AFTER window counts from when the paid call starts, not from enqueue: a job
    # that sat in the queue must not be reclaimable as "crashed" while it is spending.
    # The 1 µs floor keeps the new stamp distinct from the claim's even within a tick.
    def self.run(archetype, started_at:)
      running_at = [Time.current.floor(6), started_at + Rational(1, 1_000_000)].max
      taken = BodyArchetype.where(id: archetype.id, generation_state: BodyArchetype::BUILDING,
                                  generation_started_at: started_at)
                           .update_all(generation_started_at: running_at, updated_at: Time.current)
      return unless taken == 1

      new(archetype).call
      finish(archetype, running_at, BodyArchetype::DONE)
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = archetype
      log.target_name = archetype.slug
      log.save!
      finish(archetype, running_at, BodyArchetype::FAILED, e.message) if running_at
    end

    def self.finish(archetype, started_at, state, error = nil)
      BodyArchetype.where(id: archetype.id, generation_state: BodyArchetype::BUILDING,
                          generation_started_at: started_at)
                   .update_all(generation_state: state, generation_error: error, updated_at: Time.current)
    end

    def initialize(archetype)
      @archetype = archetype
    end

    # ⚠ SPENDS MONEY: one image. Stores our copy first, then writes the row.
    def call
      row = self.class.row
      raise Refused, "No image generator can draw an archetype." if row.nil?

      prompt = self.class.prompt_for(@archetype)
      result = ImageGeneration::Adapter.for(row).new(row)
                                       .generate_and_wait(prompt: prompt, reference_urls: [], text_only: true)
      raise ImageGeneration::GenerationFailed, "#{row.label} returned no image" unless result.any?

      url = Appearances::StoreGeneratedImage.call(result.primary_url, subject: @archetype.slug,
                                                                      prefix: STORAGE_PREFIX)
      @archetype.update!(image_url: url, image_prompt: prompt, generated_at: Time.current,
                         billable_units: result.billable_units)
      @archetype
    end
  end
end

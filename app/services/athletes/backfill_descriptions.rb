module Athletes
  # FILL build, skin_tone AND hair_description FOR EVERY ATHLETE THAT LACKS THEM,
  # resumably, and never overwrite one that is already there.
  #
  # Measured on production 2026-09-26: 2,051 athletes, ZERO with any of the three.
  # Those columns feed Athlete#physical_brief, which Appearance#generation_brief and
  # Content::AssetsAgent both fold into the text an image generator works from — so
  # until this runs, every character prompt in the ecosystem is the operator's typed
  # descriptor plus nothing.
  #
  # TWO SOURCES, NOT ONE, and they cost different amounts:
  #
  #   build         <- the athlete's recorded height and weight. Free, no API call,
  #                    and available for all 2,051 rows including the 8 with no
  #                    cached headshot. A headshot cannot see a body; a measurement
  #                    can. (Athletes::BuildFromMeasurements)
  #   skin_tone     <- one vision call over the cached headshot, ~$0.0008.
  #   hair_desc.       (Athletes::DescribeFromHeadshot)
  #
  # THE COLUMNS ARE THE PROGRESS. Nothing records where a run stopped because
  # nothing has to: a complete row is skipped, so the next run resumes exactly where
  # this one left off, and a run interrupted halfway costs nothing but the calls it
  # had already paid for. Same property as `nfl:upload_headshots`, whose ImageCache
  # rows are its progress.
  #
  # NEVER OVERWRITES. A value already on file came from a human or a better source,
  # and both outrank this. #fill_blanks is the only writer and it assigns a field
  # only when that field is blank, so the pass is idempotent by construction rather
  # than by a guard somebody has to remember to check.
  #
  # ONE FAILURE NEVER ABORTS THE RUN. Each athlete is rescued individually and
  # counted; the verdict is graded at the end by the rake task, which exits non-zero
  # when the run failed more than it managed or found work and did none of it.
  class BackfillDescriptions
    # Seconds to wait after each PAID call, so a cold run of ~2,000 is a polite
    # client rather than a burst. Paid only on a vision call, so the warm re-run —
    # which makes none — is not slowed by it.
    DEFAULT_PAUSE = 0.2

    # One athlete's outcome, for the operator to read. This is what the sample of 20
    # is FOR: the whole value of the feature is whether the descriptions are any
    # good, and only a human can judge that.
    Row = Data.define(:slug, :position, :build, :skin_tone, :hair_description, :status)

    Outcome = Data.define(
      :considered, :updated, :build_filled, :described, :vision_calls,
      :skipped_complete, :skipped_no_headshot, :failed, :usage, :cost, :rows
    ) do
      # Work the run FOUND, which is a different question from work it attempted.
      def needed = considered - skipped_complete

      # Cost per paid call, for the operator's go/no-go on the full set. Nil rather
      # than a division by zero when nothing was billed.
      def cost_per_call
        return nil if vision_calls.zero? || cost.nil?

        cost / vision_calls
      end
    end

    # `describer` is a seam so the suite can drive the whole loop without a
    # transport; production passes nothing.
    def initialize(limit: nil, pause: DEFAULT_PAUSE, describer: nil, logger: nil)
      @limit = limit
      @pause = pause.to_f
      @describer = describer || DescribeFromHeadshot.new
      @logger = logger
    end

    # `limit` caps ATHLETES CHANGED, which bounds both the spend and the writes with
    # one number. An operator asking for "a sample of 20 before we spend on 2,000"
    # means twenty rows they can read, and they have not approved a bulk write to
    # the other two thousand either — not even a free one. So the run STOPS at the
    # limit rather than walking on to fill the cheap column everywhere.
    def call
      considered = 0
      updated = 0
      build_filled = 0
      described = 0
      vision_calls = 0
      skipped_complete = 0
      skipped_no_headshot = 0
      failed = 0
      usage = { "input" => 0, "output" => 0 }
      rows = []

      candidates.find_each do |athlete|
        break if @limit && updated >= @limit

        considered += 1

        if complete?(athlete)
          skipped_complete += 1
          next
        end

        # Declared out here so the pause below reads the call THIS iteration made,
        # not a predicate re-evaluated after the fields were written — which would
        # have inverted it, since a filled field no longer wants vision.
        made_call = false

        begin
          result = nil

          if wants_vision?(athlete)
            if headshot?(athlete)
              made_call = true
              vision_calls += 1
              result = @describer.call(athlete)
              accumulate(usage, result.usage)
              described += 1 if result.any?
            else
              # NOT A FAILURE — a data gap. 8 of 2,051 athletes have no cached
              # headshot (measured 2026-09-26), and they still get their build from
              # the measurement below. Counted separately so a run with no vision
              # output can be told from a run whose calls all failed.
              skipped_no_headshot += 1
            end
          end

          changed = fill_blanks(athlete, result)
          next if changed.empty?

          athlete.save!
          updated += 1
          build_filled += 1 if changed.include?(:build)
          rows << row_for(athlete, status: changed.join("+"))
          log(" [+] #{athlete.person_slug.ljust(28)} #{changed.join(', ')}")
        rescue StandardError => e
          # ONE ATHLETE'S FAILURE IS ONE ATHLETE'S FAILURE. Counted, named, and the
          # loop continues — a dead S3 object or a refused call must not cost the
          # other two thousand their description.
          failed += 1
          log(" [!] #{athlete.person_slug}: #{e.class}: #{e.message}")
          Appearances::FailureLog.file(e, target: athlete)
        ensure
          # PAID CALLS ONLY, and in an `ensure` so a failed call is still followed by
          # the back-off — a run failing on rate limits must not then retry faster
          # than a run succeeding.
          sleep @pause if made_call && @pause.positive?
        end
      end

      Outcome.new(
        considered: considered, updated: updated, build_filled: build_filled,
        described: described, vision_calls: vision_calls,
        skipped_complete: skipped_complete, skipped_no_headshot: skipped_no_headshot,
        failed: failed, usage: usage,
        cost: UsagePricing.price(usage, DescribeFromHeadshot::MODEL), rows: rows
      )
    end

    private

    # EVERY ATHLETE, with the headshot rows preloaded. The scope is not narrowed to
    # "missing a field" in SQL because #complete? is the one definition of done and
    # a second one in a WHERE clause is a second thing to keep in agreement; the
    # skip is counted instead, which is also what makes the warm re-run's "found no
    # work" verdict readable.
    def candidates
      Athlete.includes(:image_caches).order(:id)
    end

    def complete?(athlete)
      athlete.build.present? && athlete.skin_tone.present? && athlete.hair_description.present?
    end

    def wants_vision?(athlete)
      athlete.skin_tone.blank? || athlete.hair_description.blank?
    end

    def headshot?(athlete)
      athlete.image_caches.any? do |c|
        c.purpose == DescribeFromHeadshot::HEADSHOT_PURPOSE &&
          c.variant == DescribeFromHeadshot::HEADSHOT_VARIANT
      end
    end

    # THE ONLY WRITER, and the only place the never-overwrite rule lives. Returns the
    # field names it actually set, so the caller counts and reports rather than
    # guessing from a dirty-check.
    #
    # Each field is considered independently: an athlete who already has a hand-written
    # skin tone but no hair still gets hair, and keeps the skin tone.
    def fill_blanks(athlete, result)
      changed = []

      if athlete.build.blank?
        derived = BuildFromMeasurements.call(athlete)
        if derived.present?
          athlete.build = derived
          changed << :build
        end
      end

      if result
        if athlete.skin_tone.blank? && result.skin_tone.present?
          athlete.skin_tone = result.skin_tone
          changed << :skin_tone
        end

        if athlete.hair_description.blank? && result.hair_description.present?
          athlete.hair_description = result.hair_description
          changed << :hair_description
        end
      end

      changed
    end

    def accumulate(total, usage)
      return if usage.blank?

      total["input"] += usage["input"].to_i
      total["output"] += usage["output"].to_i
    end

    def row_for(athlete, status:)
      Row.new(slug: athlete.person_slug, position: athlete.position, build: athlete.build,
              skin_tone: athlete.skin_tone, hair_description: athlete.hair_description,
              status: status)
    end

    def log(line)
      @logger&.call(line)
    end
  end
end

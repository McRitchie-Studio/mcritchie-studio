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
  #   skin_tone     <- one vision call over the cached headshot, $0.00109 measured
  #   hair_desc.       over a 23-call sample. (Athletes::DescribeFromHeadshot)
  #
  # SO THE RUN IS GRADED PER LANE, NOT IN TOTAL, and that is the point of the ledger
  # below rather than a detail of it. The free lane always succeeds and covers every
  # row; the paid lane can fail silently, because its describer degrades to a blank
  # answer rather than raising. A counter that sums them cannot tell "did the cheap
  # half" from "did the whole job": one full pass with a dead credential fills 2,051
  # builds, writes zero descriptions, and reads as a total success. Every counter here
  # therefore belongs to exactly one lane, and each of the rake task's verdict rules
  # speaks about one lane's own evidence.
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

    # WHAT THE RUN DID, LANE BY LANE. Read the two blocks as two separate reports on
    # two separate sources, because that is what the verdict rules do:
    #
    #   the run       considered, skipped_complete, updated, failed
    #   free lane     build_wanted   -> build_measured -> build_filled
    #   paid lane     vision_wanted  -> vision_asked   -> vision_billed -> described
    #
    # Each lane reads left to right as "wanted it" -> "a source could answer" ->
    # "something came back". A gap between the first two columns is a DATA gap and is
    # silent; a gap between the last two is the lane not working, and that is what
    # exits non-zero.
    Outcome = Data.define(
      :considered, :skipped_complete, :updated, :failed,
      :build_wanted, :build_measured, :build_filled,
      :vision_armed, :vision_wanted, :skipped_no_headshot,
      :vision_asked, :vision_billed, :described,
      :usage, :cost, :rows
    ) do
      # Rows that wanted a build and carried no measurement to derive one from. A
      # data gap, reported rather than graded.
      def build_unmeasured = build_wanted - build_measured

      # Cost per call that was actually BILLED. Dividing by `vision_asked` would
      # under-report the price of a run whose calls mostly never left the process.
      def cost_per_billed_call
        return nil if vision_billed.zero? || cost.nil?

        cost / vision_billed
      end
    end

    # The same fields while the run is still counting them. A Struct rather than a
    # Hash so a mistyped counter raises instead of silently reading zero — the entire
    # defect class this ledger exists to close is a counter nobody read.
    Ledger = Struct.new(
      :considered, :skipped_complete, :updated, :failed,
      :build_wanted, :build_measured, :build_filled,
      :vision_wanted, :skipped_no_headshot, :vision_asked, :vision_billed, :described
    ) do
      def self.zero = new(*Array.new(members.size, 0))
    end

    # `describer` is a seam, and it must answer TWO questions: #call(athlete) for one
    # athlete's description, and #armed? for whether the paid lane can make a call at
    # all — asked once per run, before any athlete is handed over.
    #
    # THE RAKE TASK PASSES ONE IN, so its pre-run credential warning and its post-run
    # lane report read the same object rather than two answers to two different
    # questions. The default is here for a caller that has no opinion, and for the
    # suite, which injects a double.
    def initialize(limit: nil, pause: DEFAULT_PAUSE, describer: nil, logger: nil)
      @limit = limit
      @pause = pause.to_f
      @describer = describer || DescribeFromHeadshot.new
      @logger = logger
    end

    # `limit` caps ATHLETES CHANGED. An operator asking for "a sample of 20 before we
    # spend on 2,000" means twenty rows they can read, and they have not approved a
    # bulk write to the other two thousand either — not even a free one. So the run
    # STOPS at the limit rather than walking on to fill the cheap column everywhere.
    #
    # IT BOUNDS THE WRITES, NOT THE SPEND, and the difference is real though small.
    # The walk advances on CHANGES, so an athlete who is paid for and yields nothing
    # to write does not consume the limit: one whose build is already on file and
    # whose call answers null for both fields leaves `changed` empty, and the loop
    # moves on having billed a call. DESCRIBE_LIMIT=20 can therefore cost more than
    # twenty calls. It cannot run away — `find_each` visits each athlete exactly once,
    # so the ceiling is one full pass, ~2,043 calls, ~$2.25 — but "20 rows" is a cap
    # on rows and the bill is bounded by the table, not by the flag.
    def call
      tally = Ledger.zero
      usage = { "input" => 0, "output" => 0 }
      rows = []

      # ASKED ONCE, FOR THE WHOLE RUN. An unarmed describer answers every athlete
      # with a blank Result without making a call, so handing it 2,043 athletes would
      # bill nothing, describe nothing, and report 2,043 "asks" — a number that reads
      # like a spend and is not one. The lane is either on or off; say so once.
      armed = @describer.armed?

      candidates.find_each do |athlete|
        break if @limit && tally.updated >= @limit

        tally.considered += 1

        if complete?(athlete)
          tally.skipped_complete += 1
          next
        end

        # Declared out here so the pause below reads the call THIS iteration made,
        # not a predicate re-evaluated after the fields were written — which would
        # have inverted it, since a filled field no longer wants vision.
        asked = false

        begin
          result = nil
          wants = wants_vision?(athlete)
          tally.vision_wanted += 1 if wants

          if wants && armed
            if headshot?(athlete)
              asked = true
              tally.vision_asked += 1
              result = @describer.call(athlete)
              # BILLED IS THE EVIDENCE A CALL HAPPENED, and it is separate from
              # DESCRIBED on purpose. Token usage means the API answered; a described
              # field means the answer was usable. A covered face bills and describes
              # nothing, an invalid credential does neither, and only the paid lane's
              # verdict can tell those apart (lib/tasks/athletes.rake, rule 3).
              tally.vision_billed += 1 if result.billed?
              tally.described += 1 if result.any?
              accumulate(usage, result.usage)
            else
              # NOT A FAILURE — a data gap. 8 of 2,051 athletes have no cached
              # headshot (measured 2026-09-26), and they still get their build from
              # the measurement below. Counted separately so a run with no vision
              # output can be told from a run whose calls all failed.
              tally.skipped_no_headshot += 1
            end
          end

          changed = fill_blanks(athlete, result, tally)
          next if changed.empty?

          athlete.save!
          tally.updated += 1
          tally.build_filled += 1 if changed.include?(:build)
          rows << row_for(athlete, status: changed.join("+"))
          log(" [+] #{athlete.person_slug.ljust(28)} #{changed.join(', ')}")
        rescue StandardError => e
          # ONE ATHLETE'S FAILURE IS ONE ATHLETE'S FAILURE. Counted, named, and the
          # loop continues — a dead S3 object or a refused call must not cost the
          # other two thousand their description.
          #
          # THE PAID DESCRIBER DOES NOT REACH HERE. It degrades to a blank Result by
          # contract, so what this rescue actually catches is the WRITE path: a
          # validation on a row that predates it, a database error, an ErrorLog insert
          # that itself fails. That is why a total vision failure cannot be read off
          # `failed`, and why the paid lane is graded on its own evidence instead.
          tally.failed += 1
          log(" [!] #{athlete.person_slug}: #{e.class}: #{e.message}")
          Appearances::FailureLog.file(e, target: athlete)
        ensure
          # ASKED CALLS ONLY, and in an `ensure` so a failed call is still followed by
          # the back-off — a run failing on rate limits must not then retry faster
          # than a run succeeding. Keyed on the ask rather than on the bill for the
          # same reason: a 429 is unbilled, and it is the case that most needs the wait.
          sleep @pause if asked && @pause.positive?
        end
      end

      Outcome.new(
        considered: tally.considered, skipped_complete: tally.skipped_complete,
        updated: tally.updated, failed: tally.failed,
        build_wanted: tally.build_wanted, build_measured: tally.build_measured,
        build_filled: tally.build_filled,
        vision_armed: armed, vision_wanted: tally.vision_wanted,
        skipped_no_headshot: tally.skipped_no_headshot,
        vision_asked: tally.vision_asked, vision_billed: tally.vision_billed,
        described: tally.described, usage: usage,
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

    # WANTS THE PAID LANE: either description is still missing.
    #
    # A LEGITIMATELY NULL ANSWER IS RE-ASKED ON EVERY FUTURE RUN, and closing that
    # needs a record this schema does not carry. A covered face, a hood, a placeholder
    # crop — the honest answer is null, the row therefore never becomes #complete?,
    # and the next run pays to ask the same question again. The standing cost is small
    # (19 of 19 sampled athletes answered both fields), but it is also the reason the
    # paid lane's verdict is graded on BILLING rather than on output: a lane that is
    # re-asking known-null rows looks identical, from the counters, to one that is
    # answering nothing. Recording "asked, and the answer was null" fixes both and is
    # a column rather than an accounting change, so it is not in this pass.
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
    # `tally` is passed in because the FREE LANE'S accounting belongs where its one
    # decision is made. Counting "wanted a build" in the loop would mean a second copy
    # of `athlete.build.blank?` to keep in agreement with this one.
    def fill_blanks(athlete, result, tally)
      changed = []

      if athlete.build.blank?
        tally.build_wanted += 1
        # THE INPUT, NOT THE VERDICT. Counted before the deriver runs and independently
        # of what it says, so a deriver that answered nil for every row is visible as a
        # lane that had its input and wrote nothing, rather than as a lane with nothing
        # to do. See Athletes::BuildFromMeasurements.measured?.
        tally.build_measured += 1 if BuildFromMeasurements.measured?(athlete)

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

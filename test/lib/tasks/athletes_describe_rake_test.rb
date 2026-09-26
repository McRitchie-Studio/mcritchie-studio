require "test_helper"
require "rake"

# [integration] THE BACKFILL TASK AS THE OPERATOR RUNS IT — and specifically its
# EXIT CODE, which is the property a service-level test cannot reach.
#
# WHY THAT IS THE PROPERTY WORTH A TASK-LEVEL TEST. `nfl:upload_headshots` — the
# sibling task that cached the very headshots this one reads — spent its whole life
# reporting a total failure as a success: `candidates: 2048`, `cached: 0`, a clean
# summary, exit 0. It found 2,048 athletes, declined every one of them over a
# precondition nobody could satisfy, and said nothing was wrong. Nobody noticed until
# somebody went looking for the avatars.
#
# THE RULES ARE GRADED PER LANE, and that is the whole design. Two sources answer
# different columns at different prices: build comes off the recorded height and
# weight and always succeeds, while skin tone and hair come from a paid call whose
# describer degrades to a blank answer rather than raising. A rule that reads a
# counter summing the two cannot tell "did the cheap half" from "did the job" — one
# full pass with a dead credential fills 2,051 builds, describes nobody, and every
# summed counter reads healthy.
#
#   1. THE PASS BROKE DOWN — more raises than writes. Its population is the WRITE
#      path — a row that no longer satisfies a validation, a database error — because
#      the describer never raises. NOT an orphaned row: measured here, an athlete whose
#      person is deleted is still `valid?`, since `belongs_to :person` is not required.
#   2. THE FREE LANE HAD ITS INPUT AND WROTE NOTHING — graded on height and weight
#      being on file, never on the deriver's own verdict.
#   3. THE PAID LANE NEVER REACHED THE API — graded on whether a single call was
#      billed a token, which rules 1 and 2 are both structurally blind to.
#
# AND THE TWO CASES THAT MUST STAY QUIET, because a rule that fires on either gets
# disabled within a week:
#
#   * the warm re-run over a COMPLETE row, which legitimately does nothing; and
#   * the re-run over a row NO SOURCE CAN EVER COMPLETE — an athlete with no cached
#     headshot, whose skin tone and hair have no second source. Those 8 rows are found
#     on every run for ever. Grading them as work declined is not a theoretical false
#     positive: it is what the first cut of this task did, on every healthy re-run.
class AthletesDescribeRakeTest < ActiveSupport::TestCase
  DFH = Athletes::DescribeFromHeadshot

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("athletes:describe_from_headshots")
    ImageCache.where(owner_type: "Athlete").delete_all
    Athlete.delete_all
  end

  # A HEALTHY RUN EXITS 0 AND PRINTS WHAT IT WROTE. The printed table is the
  # deliverable of the sample run — the operator reads it to decide whether to spend
  # on the rest, and a run that wrote rows without showing them is useless to them.
  test "a healthy run exits zero and prints the descriptions it wrote" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    status, output = run_task(describer: stub_describer)

    assert_equal 0, status
    assert_match "updated:                  1", output
    assert_match "build lane — free", output
    assert_match "had the measurements:   1", output
    assert_match "filled:                 1", output
    assert_match "vision lane — paid", output
    assert_match "billed (call landed):   1", output
    assert_match "described:              1", output
    assert_match "WHAT IT WROTE", output
    assert_match "6 ft 0 in, 197 lb; athletic, well-built", output
    assert_match "medium-deep, warm undertone", output
    assert_match "short black fade, full beard", output
  end

  test "it reports the measured cost and projects the remainder" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    # A second athlete left undone, so there is a remainder to project onto.
    athlete_with_headshot(height_inches: 74, weight_lbs: 240)

    status, output = run_task(describer: stub_describer, env: { "DESCRIBE_LIMIT" => "1" })

    assert_equal 0, status
    assert_match "asked:                  1", output
    assert_match "billed (call landed):   1", output
    assert_match(/cost \(#{Regexp.escape(DFH::MODEL)} list\): \$0\.0007/, output)
    assert_match "cost per billed call:", output
    assert_match(/projected for the remaining 1:/, output)
  end

  # RULE 1 — the pass itself broke down.
  #
  # THE RAISE COMES FROM THE WRITE, which is the only thing in this loop that raises
  # in production. The describer rescues StandardError and returns a blank Result by
  # contract, so a test that made IT explode would pin the rule against a shape
  # production cannot produce — and rule 3 below exists precisely because it cannot.
  #
  # WHAT DOES RAISE: a row that does not satisfy a current validation. `save!` is the
  # first thing to re-validate a record this pass only meant to add three fields to,
  # and a pass over 2,051 rows accumulated by six importers — at least one of which
  # writes through `update_column` (Pff::ImportCsv) — is exactly where such a row
  # surfaces. A blank `sport` is one: the column is NOT NULL, so an empty string sits
  # on disk happily and fails `validates :sport, presence: true` on the next save.
  test "a run that raised on more athletes than it wrote exits non-zero" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    athlete.update_column(:sport, "")

    status, output = run_task(describer: stub_describer)

    refute_equal 0, status, "a run that could not write a single row must not exit 0"
    assert_match "raised on 1 of the 1 athlete(s) it tried to write", output
    assert_match "/admin/error_logs", output, "and where the rows are"
    assert_match "degrades rather than raising", output,
                 "the abort must say a raise here is the WRITE failing, not a description"
  end

  # RULE 2 — THE FREE LANE HAD ITS INPUT AND WROTE NOTHING. Graded on the measurements
  # being on file rather than on what the deriver said about them, because a deriver
  # that answered nil for every row would otherwise report that it had nothing to do —
  # `candidates: 2048`, `cached: 0`, exit 0, which is how the sibling task cost 2,048
  # athletes their avatar.
  test "a free lane that had its measurements and wrote no build exits non-zero" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    status, output = Athletes::BuildFromMeasurements.stub(:call, nil) do
      run_task(describer: stub_describer)
    end

    refute_equal 0, status, "the input was on the record and nothing came of it"
    assert_match "had height and weight on file for 1 athlete(s)", output
    assert_match "wrote none of them", output
    assert_match "athletes:description_coverage", output, "the abort must name the next read"
  end

  # RULE 3 — A TOTAL VISION FAILURE, and the case that makes the per-lane split
  # necessary rather than tidy. The describer here has the REAL production contract:
  # it returns BLANK and never raises, which is what a present-but-INVALID credential,
  # a sustained 429 and an unreadable S3 object all look like from the loop. So
  # `failed` stays 0, and the free build lane fills every row and drives `updated` up.
  # Both other rules are false. Without rule 3 this run exits 0 having described
  # nobody and left an ErrorLog row per athlete that nobody was told to read.
  test "a total vision failure exits non-zero even while the free lane fills every row" do
    athlete = athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    status, output = run_task(describer: blank_describer)

    refute_equal 0, status,
                 "asked for 1 description, billed nothing, described nobody — exiting 0 " \
                 "here is nfl:upload_headshots reproduced for the half that costs money"
    assert_match "not one call was billed", output
    assert_match DFH::API_KEY_ENV, output, "the abort must name the credential to check"
    assert_match "/admin/error_logs", output
    assert_equal "6 ft 0 in, 197 lb; athletic, well-built", athlete.reload.build,
                 "the free lane did its half, which is exactly what made the totals look healthy"
  end

  # THE FALSE POSITIVE THAT WOULD GET THE PER-LANE RULES DISABLED, part one: the warm
  # re-run over a COMPLETE row. Nothing is wanted, so no lane has anything to report.
  test "the warm re-run does nothing, says nothing, and exits zero" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197,
                          build: "done", skin_tone: "done", hair_description: "done")

    status, output = run_task(describer: stub_describer)

    assert_equal 0, status, "a re-run that legitimately has no work must stay quiet"
    assert_match "skipped (already done):   1", output
    refute_match "wrote none of them", output
    refute_match "WHAT IT WROTE", output
  end

  # PART TWO, AND THE ONE THE FIRST CUT OF THIS TASK GOT WRONG: a row NO SOURCE CAN
  # EVER COMPLETE. 8 of 2,051 production athletes have no cached headshot, and skin
  # tone and hair have no second source, so those rows can never satisfy #complete?.
  # They are found on every run for ever, and there is nothing to be done about them.
  #
  # The first cut counted them as `needed` and aborted with "found 8 athlete(s)
  # needing a description and wrote none of them" on every healthy re-run — the exact
  # false positive its own comment said could not happen. It passed its suite because
  # the blessing test used a FULLY COMPLETE athlete, which is a different row.
  test "a re-run over an athlete no source can complete exits zero, for ever" do
    athlete = bare_athlete(height_inches: 74, weight_lbs: 240)

    first_status, = run_task(describer: stub_describer)

    assert_equal 0, first_status
    assert_equal "6 ft 2 in, 240 lb; solidly built, muscular", athlete.reload.build
    assert_nil athlete.skin_tone, "no cached headshot, and no second source for skin tone"

    status, output = run_task(describer: stub_describer)

    assert_equal 0, status,
                 "the steady state of a finished pass must exit 0 — a rule that fires " \
                 "on every re-run for ever is a rule that gets disabled"
    assert_match "no cached headshot:     1", output
    refute_match "wrote none of them", output
    refute_match "not one call was billed", output
  end

  # PART THREE: the row whose honest answer is null. A covered face bills a call and
  # describes nothing, and the row never becomes #complete?, so it is re-asked on
  # every future run. Grading the paid lane on OUTPUT rather than on BILLING would
  # abort here for ever too.
  test "re-asking an athlete whose honest answer is null exits zero" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)
    covered = describer_double do
      DFH::Result.new(skin_tone: nil, hair_description: nil, person_visible: false,
                      usage: { "input" => 505, "output" => 12 }, model: DFH::MODEL)
    end

    run_task(describer: covered)
    status, output = run_task(describer: covered)

    assert_equal 0, status, "a billed call is evidence the lane works, whatever it answered"
    assert_match "billed (call landed):   1", output
    assert_match "described:              0", output
    refute_match "not one call was billed", output
  end

  # A MISSING CREDENTIAL IS A WARNING, NOT AN ABORT: build comes off the recorded
  # height and weight and needs no credential at all, so the run still does real work.
  test "with no credential it warns, fills build anyway, and exits zero" do
    athlete = bare_athlete(height_inches: 74, weight_lbs: 240)
    # A HEADSHOT ATHLETE TOO, so the paid lane has something it WOULD ask about. An
    # unarmed describer answers blank without making a call, so asking anyway would
    # report an ask that was never billed — and trip the paid lane's verdict on a run
    # whose only fault is a missing credential the warning above already named.
    athlete_with_headshot(height_inches: 72, weight_lbs: 197)

    status, output = with_env(DFH::API_KEY_ENV, nil) { run_task(describer: nil) }

    assert_equal 0, status
    assert_match "#{DFH::API_KEY_ENV} is not set", output
    assert_match "filling build from measurements only", output
    assert_match "vision lane — NOT ARMED", output,
                 "an unarmed lane reports that it went unasked, not 1 ask at $0.00"
    assert_match "went unasked", output
    refute_match "not one call was billed", output,
                 "the paid verdict must not fire on a lane that was never armed"
    assert_equal "6 ft 2 in, 240 lb; solidly built, muscular", athlete.reload.build
  end

  # The read-only companion, so the operator's go/no-go needs no rails console.
  test "the coverage report counts each source without writing anything" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197, skin_tone: "light")

    status, output = run_task(task: "athletes:description_coverage")

    assert_equal 0, status
    assert_match "athletes:                     1", output
    assert_match(/with skin_tone\s+1/, output)
    assert_match(/with build\s+0/, output)
    assert_match(/with height AND weight\s+1/, output)
    assert_match(/with a cached 400px headshot 1/, output)
  end

  private

  # Runs the task the way the operator does. Only ONE thing is swapped — the
  # constructor of the paid describer — so the real rake body, the real
  # Athletes::BackfillDescriptions, and the real verdict rules all run. Stubbing
  # BackfillDescriptions itself would have skipped the loop these tests are about.
  #
  # `describer: nil` leaves the real describer in place, which is safe twice over:
  # Athletes::VisionTransport is armed to raise suite-wide, and the tests that do it
  # run with no credential.
  def run_task(task: "athletes:describe_from_headshots", describer: nil, env: {})
    status = 0
    Rake::Task[task].reenable

    invoke = lambda do
      out, err = capture_io do
        Rake::Task[task].invoke
      rescue SystemExit => e
        status = e.status
      end
      [status, out + err]
    end

    with_envs(env) do
      if describer
        # Wrapped in a lambda because minitest's `stub` CALLS a value that responds
        # to #call — and the describer does, with one argument. Passing it bare makes
        # minitest invoke it as the constructor, arity zero.
        DFH.stub(:new, ->(*) { describer }) { invoke.call }
      else
        invoke.call
      end
    end
  end

  def with_envs(pairs, &block)
    return block.call if pairs.empty?

    key, value = pairs.first
    with_env(key, value) { with_envs(pairs.except(key), &block) }
  end

  # A DESCRIBER WITH THE PRODUCTION CONTRACT: it answers #armed?, which the backfill
  # asks before handing over an athlete, and it degrades rather than raising, because
  # Athletes::DescribeFromHeadshot rescues StandardError and returns a blank Result.
  # Nothing here may raise — a fixture whose shape production cannot produce is a test
  # that does not cover the case it names.
  def describer_double(armed: true, &answer)
    Struct.new(:answer, :armed) do
      def call(athlete) = answer.call(athlete)
      def armed? = armed
    end.new(answer, armed)
  end

  def stub_describer
    result = DFH::Result.new(skin_tone: "medium-deep, warm undertone",
                             hair_description: "short black fade, full beard",
                             person_visible: true,
                             usage: { "input" => 505, "output" => 38 },
                             model: DFH::MODEL)
    describer_double { result }
  end

  # WHAT AN INVALID CREDENTIAL, A SUSTAINED 429 AND A DEAD S3 OBJECT ALL LOOK LIKE
  # from the loop: a blank Result carrying no usage, and no exception at all.
  def blank_describer = describer_double { DFH::BLANK }

  def bare_athlete(**attrs)
    person = Person.create!(first_name: "Rake", last_name: SecureRandom.hex(4), athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "WR", **attrs)
  end

  def athlete_with_headshot(**attrs)
    athlete = bare_athlete(**attrs)
    ImageCache.create!(owner: athlete, purpose: "headshot", variant: DFH::HEADSHOT_VARIANT,
                       s3_key: "headshots/nfl/free-agents/#{athlete.person_slug}/400.png",
                       content_type: "image/png")
    athlete.reload
  end
end

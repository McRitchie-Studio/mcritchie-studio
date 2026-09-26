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
# So this task carries two verdict rules, and the two are disjoint by construction:
#
#   1. MORE FAILURES THAN SUCCESSES — the pass is not working (usually a credential).
#   2. FOUND WORK AND DID NONE OF IT — the rule above is structurally blind to this,
#      because with 0 successes and 0 failures `failed > updated` is false.
#
# And the case that must stay QUIET: the warm re-run, which legitimately does nothing.
# A rule that fired there would cry wolf on every run after the first and be disabled
# within a week.
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
    assert_match "vision calls:             1", output
    assert_match(/cost \(#{Regexp.escape(DFH::MODEL)} list\): \$0\.0007/, output)
    assert_match "cost per call:", output
    assert_match(/projected for the remaining 1:/, output)
  end

  # RULE 1 — the pass is not working.
  test "a run whose calls mostly failed exits non-zero and names the likely cause" do
    3.times { |i| athlete_with_headshot(height_inches: 72 + i, weight_lbs: 197, build: "already set") }

    status, output = run_task(describer: exploding_describer)

    refute_equal 0, status, "a run where every attempt failed must not exit 0"
    assert_match "failed 3 of 3 attempts", output
    assert_match DFH::API_KEY_ENV, output, "the abort must name the credential to check"
    assert_match "/admin/error_logs", output, "and where the rows are"
  end

  # RULE 2 — THE ONE THAT COST 2,048 ATHLETES THEIR AVATAR on the sibling task.
  # Found work, wrote none, and the attempts-majority rule above cannot see it.
  test "a run that found work and wrote none of it exits non-zero" do
    # No headshot and no measurements: there is nothing either source can answer, so
    # the athlete is found, attempted by neither, and written by neither.
    bare_athlete(height_inches: nil, weight_lbs: nil)

    status, output = run_task(describer: stub_describer)

    refute_equal 0, status,
                 "found 1 athlete needing a description and wrote 0 — exiting 0 here is " \
                 "exactly how nfl:upload_headshots hid a total failure for its whole life"
    assert_match "found 1 athlete(s) needing a description and wrote none", output
    assert_match "athletes:description_coverage", output, "the abort must name the next read"
  end

  # THE FALSE POSITIVE THAT WOULD GET RULE 2 DISABLED. `needed` subtracts the
  # already-complete rows, so the warm re-run has nothing to complain about.
  test "the warm re-run does nothing, says nothing, and exits zero" do
    athlete_with_headshot(height_inches: 72, weight_lbs: 197,
                          build: "done", skin_tone: "done", hair_description: "done")

    status, output = run_task(describer: stub_describer)

    assert_equal 0, status, "a re-run that legitimately has no work must stay quiet"
    assert_match "skipped (already done):   1", output
    refute_match "found", output
    refute_match "WHAT IT WROTE", output
  end

  # A MISSING CREDENTIAL IS A WARNING, NOT AN ABORT: build comes off the recorded
  # height and weight and needs no credential at all, so the run still does real work.
  test "with no credential it warns, fills build anyway, and exits zero" do
    athlete = bare_athlete(height_inches: 74, weight_lbs: 240)

    status, output = with_env(DFH::API_KEY_ENV, nil) { run_task(describer: nil) }

    assert_equal 0, status
    assert_match "#{DFH::API_KEY_ENV} is not set", output
    assert_match "filling build from measurements only", output
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

  def stub_describer
    result = DFH::Result.new(skin_tone: "medium-deep, warm undertone",
                             hair_description: "short black fade, full beard",
                             person_visible: true,
                             usage: { "input" => 505, "output" => 38 },
                             model: DFH::MODEL)
    Struct.new(:result) { def call(_athlete) = result }.new(result)
  end

  def exploding_describer
    Struct.new(:x) { def call(_a) = raise(IOError, "connection reset") }.new(nil)
  end

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

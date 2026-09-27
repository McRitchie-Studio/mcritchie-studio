require "test_helper"
require "rake"

# [integration] THE OPERATOR'S DOOR ONTO Athletes::AcquireOrValidate, driven twice around
# the loop its refusal used to print.
#
# WHY THIS TIER AND NOT ONLY THE SERVICE TEST. A refusal is only worth anything if the
# person reading it can act on it, and what that person reads is `print_report`'s stdout —
# not a `Report` struct. The service test proves the message's Ruby runs; this proves the
# operator ever SEES it, on the path the docs tell them to take:
#
#     DRY_RUN=1 bin/rails athletes:acquire_or_validate TEAM=lv
#
# That documented sweep walks ESPN's Las Vegas roster, and A.J. Cole is the Raiders'
# punter — on file as `a-j-cole` for years while ESPN says "AJ Cole" — so the refusal and
# its remedy are what the sweep hands back for him. Before this task the printed
# instruction returned the byte-identical refusal, which a stdout test is the only tier
# that could have caught from the operator's side.
#
# ONLY THE PROVIDER IS SWAPPED, so the real rake body, the real service, the real
# `print_report` and the real verdict tally all run, and nothing leaves the machine.
class AthletesAcquireRakeTest < ActiveSupport::TestCase
  TASK = "athletes:acquire_or_validate".freeze

  # The same cut as Athletes::AcquireOrValidateTest makes: the operator's characters,
  # lifted out of the output rather than retyped, so a message that does not run reddens.
  ALIAS_REMEDY = /Person\.find_by\(slug: .*?\) \}/

  # A provider that answers from one hash. `#find` is the only route the `ESPN_ID=` door
  # takes; the roster methods exist so a wrong turn raises here instead of reaching ESPN.
  class FakeSource
    def initialize(by_id) = @by_id = by_id
    def source = :fake
    def find(source_id:) = @by_id[source_id.to_s]
    def find_on_roster(team:, name:) = raise("the ESPN_ID door must not walk a roster")
    def find_in_league(name:) = raise("the ESPN_ID door must not search the league")
    def roster(team:) = raise("the ESPN_ID door must not read a roster")
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    teams(:buffalo_bills)
  end

  # THE WHOLE POINT OF THE TASK, from the operator's chair: refused, read the line, run
  # the line, run the task again, acquired. Nothing here retypes the remedy.
  test "the printed ambiguous-name remedy can be run off stdout and the re-run lands" do
    existing = Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)

    refused = run_task
    assert_match(/\[refused: ambiguous_name\] AJ Cole/, refused)
    assert_match(/verdict: ambiguous_name=1/, refused)
    refute_match(/re-run with source_id/, refused,
                 "the operator must not be sent back around the loop")

    remedy = refused[ALIAS_REMEDY]
    assert_equal %{Person.find_by(slug: "a-j-cole").then { |p| p.update!(aliases: p.aliases.to_a | ["AJ Cole"]) }},
                 remedy, "the refusal reaches stdout whole, with its one runnable line"

    assert_difference -> { Athlete.count } => 1, -> { Person.count } => 0 do
      eval(remedy)
      @output = run_task
    end

    assert_match(/ACQUIRE A\.J\. Cole \(a-j-cole\)/, @output)
    assert_match(/verdict: acquire=1  ok=1/, @output)
    assert_equal ["AJ Cole"], existing.reload.aliases
    assert_equal "9003", Athlete.find_by(person_slug: "a-j-cole").espn_id
  end

  # A REFUSAL IS NOT A FAILURE — the task exits 0 on one deliberately, so that a 79-player
  # sweep does not stop at the first spelling nobody has settled. Pinned here because the
  # opposite choice would make the operator's next move "re-run it" rather than "read the
  # line", which is the very habit the looping remedy taught.
  test "an ambiguous name exits zero rather than reddening the sweep" do
    Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)

    status, output = run_task_with_status
    assert_equal 0, status
    assert_match(/refused: ambiguous_name/, output)
  end

  private

  def run_task(**env) = run_task_with_status(**env).last

  def run_task_with_status(**env)
    status = 0
    Rake::Task[TASK].reenable
    source = FakeSource.new("9003" => profile)

    with_envs({ "ESPN_ID" => "9003", "NO_HEADSHOT" => "1" }.merge(env)) do
      out, err = capture_io do
        # Only the constructor is swapped. Wrapped in a lambda because minitest's `stub`
        # CALLS a replacement that responds to #call, and a bare provider that grew a
        # #call would silently become the return value instead of the object.
        Espn::PlayerProfile.stub(:new, ->(*) { source }) { Rake::Task[TASK].invoke }
      rescue SystemExit => e
        status = e.status
      end
      [status, out + err]
    end
  end

  def profile
    Athletes::SourceProfile.new(
      source: :fake, source_id: "9003", first_name: "AJ", last_name: "Cole",
      jersey_number: 6, position: "P", team_slug: "buffalo-bills",
      height_inches: 76, weight_lbs: 220, headshot_url: nil, college: "NC State",
      unparsed: {}
    )
  end

  def with_envs(pairs, &block)
    return block.call if pairs.empty?

    key, value = pairs.first
    with_env(key, value) { with_envs(pairs.except(key), &block) }
  end
end

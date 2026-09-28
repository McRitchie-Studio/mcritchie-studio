require "test_helper"
require "rake"

# [unit] db/seeds/32_headshot_links.rb — the seed that carries two network lanes'
# exit codes out to `bin/ecosystem-build`.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────
#
# `SKIP_NETWORK_SEEDS=1` was a FABRICATED REMEDY. docs/agents/system/house-burn-down.md
# has told a firewalled operator to skip this phase with it for as long as that page
# has described the phase, and MEASURED 2026-09-28 a repo-wide grep found the string
# in that one sentence of prose and in no code anywhere.
#
# It was inert and harmless while `nfl:link_coach_headshots` and
# `nfl:link_coach_headshots_from_team_sites` failed quietly: a firewalled `db:seed`
# linked no coach and still exited 0. Both now abort on a run that linked nothing,
# which makes the hatch load-bearing — a rebuild behind a firewall would take
# bin/ecosystem-build's `exit 1` with it. So the variable is real, and this file is
# what keeps it real.
class HeadshotLinksSeedTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/32_headshot_links.rb").to_s
  LANES = ["nfl:link_coach_headshots", "nfl:link_coach_headshots_from_team_sites"].freeze

  setup { @was = ENV["SKIP_NETWORK_SEEDS"] }
  teardown { @was.nil? ? ENV.delete("SKIP_NETWORK_SEEDS") : ENV["SKIP_NETWORK_SEEDS"] = @was }

  test "the seed invokes both coach link lanes when nothing is skipped" do
    ENV.delete("SKIP_NETWORK_SEEDS")

    assert_equal LANES, invoked_tasks,
                 "the seed is the only caller either lane has, and it must invoke them in " \
                 "this order: ESPN's head coaches first, then NFL.com for the coordinators"
  end

  test "SKIP_NETWORK_SEEDS=1 invokes neither lane" do
    ENV["SKIP_NETWORK_SEEDS"] = "1"

    assert_empty invoked_tasks,
                 "a firewalled rebuild has no network, and both lanes now abort on a run " \
                 "that linked nothing -- so an unread variable is a rebuild that cannot finish"
  end

  # A SKIPPED SEED IS NOT A SEEDED ONE, and the skip has to say so where it can be
  # read. bin/ecosystem-build discards both streams, so this sentence is for the
  # operator who set the variable and will later wonder why every coach avatar
  # falls back.
  test "the skip says on stderr what the database will be missing" do
    ENV["SKIP_NETWORK_SEEDS"] = "1"

    out, err = capture_io { load SEED }

    assert_match(/SKIP_NETWORK_SEEDS=1/, err)
    assert_match(/espn_headshot_url/, err, "name the column that stays empty")
    assert_match(/upload_coach_headshots/, err, "name the lane that will then cache nothing")
    assert_match(/SKIPPED/, out, "the report itself must not read like a successful phase")
  end

  # THE SPELLING IS THE DOCUMENTED ONE AND NOTHING ELSE, asserted so the hatch
  # cannot quietly widen into "any truthy value". `= "1"` is what house-burn-down.md
  # tells an operator to type and what this repo's other env switches read.
  test "a value other than 1 does not skip" do
    ENV["SKIP_NETWORK_SEEDS"] = "true"

    assert_equal LANES, invoked_tasks,
                 "only the documented spelling skips; a near-miss must not silently " \
                 "produce a coach-less database"
  end

  private

  # RECORDS THE LANE NAMES WITHOUT RUNNING THEM. The tasks themselves talk to ESPN
  # and NFL.com, and what is under test here is the seed's BRANCH, not either lane's
  # behaviour -- those have their own files.
  #
  # ONLY THE TWO LANES ARE INTERCEPTED, and the narrowness is the fix rather than
  # tidiness. A stub that answered EVERY name with the recorder made this file
  # order-dependent: rake's own loader asks `Rake::Task.[]` for tasks while it
  # defines them and then calls `clear_comments` on what it gets back, so whether
  # these cases passed or raised `NoMethodError: undefined method 'clear_comments'`
  # depended on whether some earlier test had already loaded the task list.
  # MEASURED -- it surfaced as an ERROR rather than a failure under a mutation pass
  # on the gate, which is what exposed it. `load_tasks` is therefore forced here and
  # every other name is delegated to the real implementation, captured before the
  # stub takes it.
  def invoked_tasks
    Rails.application.load_tasks unless Rake::Task.task_defined?(LANES.first)
    seen = []
    recorder = Object.new
    recorder.define_singleton_method(:invoke) { |*| nil }
    real = Rake::Task.method(:[])

    intercept = lambda do |name|
      next real.call(name) unless LANES.include?(name.to_s)

      seen << name.to_s
      recorder
    end

    Rake::Task.stub(:[], intercept) { capture_io { load SEED } }
    seen
  end
end

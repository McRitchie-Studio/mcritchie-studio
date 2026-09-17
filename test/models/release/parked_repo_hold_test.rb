# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "open3"
require "tmpdir"
require_relative "../../support/session_env"
require_relative "../../support/outbound_seams"

# THE PARKED-REPO HOLD, record side (sweep-ignores-parked-repos).
#
# The conductor sweeps THREE-RUNG repos only (Release::Ladder.sweepable). A repo the
# registry parks — rolio `dormant`, tax-studio `planned`, chain-ops `blocked` — has
# no business being promoted or deployed by a sweep. But sweep_candidates took every
# `reviewed` task with no repo filter, and repo_plan never consulted the ladder, so a
# reviewed task naming a parked repo would have ridden straight onto the candidate.
#
# The decision is HOLD, not abort: such a task stays in its stage, is never attached,
# and the rest of the sweep carries on. A task naming a parked repo AND a live one is
# held WHOLE — shipping only the live half would stamp it assembled/shipped for a repo
# that never moved.
#
# The registry is a FIXTURE here: the real one merged with an invented `parked-app`,
# so these tests pin the rule and survive the day rolio is re-laddered.
class Release::ParkedRepoHoldTest < ActiveSupport::TestCase
  PARKED_APP = "parked-app"
  LIVE_APP   = "mcritchie-studio"

  def with_parked_registry(ladder: "dormant", &block)
    fixture = Release::Repos.config.deep_merge("apps" => { PARKED_APP => { "ladder" => ladder } })
    Release::Repos.stub(:config, fixture, &block)
  end

  def task_on(label, repos:, stage: "reviewed", merged: nil)
    Task.create!(title: "parked hold #{label} task", stage: stage, merged: merged,
                 metadata: { "devops" => {
                   "shape" => "backend",
                   "repositories" => repos,
                   "pr_urls" => repos.to_h { |r| [ r, "https://github.com/McRitchie-Studio/#{r}/pull/7" ] }
                 } })
  end

  # --- detection ---------------------------------------------------------------

  test "[unit] sweep_candidates does not offer a reviewed task on a parked repo" do
    with_parked_registry do
      parked = task_on("dormant", repos: [ PARKED_APP ])
      live   = task_on("live", repos: [ LIVE_APP ])

      cands = Release::Conductor.sweep_candidates

      assert_includes cands["reviewed"].map(&:slug), live.slug
      refute_includes cands["reviewed"].map(&:slug), parked.slug,
                      "a reviewed task naming a dormant repo must never be a sweep candidate"
      assert_equal [ parked.slug ], cands["parked"].map(&:slug), "it is reported as parked instead"
    end
  end

  test "[unit] a MIXED task (live + parked repo) is held whole at detection" do
    with_parked_registry do
      mixed = task_on("mixed", repos: [ LIVE_APP, PARKED_APP ])

      cands = Release::Conductor.sweep_candidates

      refute_includes cands["reviewed"].map(&:slug), mixed.slug
      assert_equal [ mixed.slug ], cands["parked"].map(&:slug)
    end
  end

  test "[unit] an assembled straggler naming a parked repo is held too" do
    with_parked_registry do
      straggler = task_on("straggler", repos: [ PARKED_APP ], stage: "assembled", merged: Task::MERGED_RELEASE)

      cands = Release::Conductor.sweep_candidates

      refute_includes cands["stragglers"].map(&:slug), straggler.slug
      assert_equal [ straggler.slug ], cands["parked"].map(&:slug)
    end
  end

  test "[unit] CONTROL: re-ladder the same repo three-rung and the task is a candidate again" do
    with_parked_registry(ladder: "three-rung") do
      task = task_on("reladdered", repos: [ PARKED_APP ])

      cands = Release::Conductor.sweep_candidates

      assert_includes cands["reviewed"].map(&:slug), task.slug,
                      "the hold must be caused by the ladder, not by the task's shape"
      assert_empty cands["parked"]
    end
  end

  # --- the CLI's detection read ----------------------------------------------------

  # `bin/release prepare` does not call sweep_candidates in-process: it builds a Ruby
  # snippet (sweep_detect_ruby) and runs it on the DEPLOYED conductor. Holding a task
  # out of "reviewed" is only half the fix — if the snippet dropped the "parked" list,
  # the task would vanish from the sweep with no HELD line, which is the silence this
  # task exists to end. So this runs bin/release's REAL snippet against the test DB
  # and feeds its rows to the plan the CLI computes.
  test "[integration] prepare's detection snippet hands a parked task to the plan, which holds it" do
    snippet, err, status = Dir.mktmpdir("parked-detect-locks") do |locks|
      Open3.capture3(OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => locks), RbConfig.ruby, "-e",
                     %(load #{Rails.root.join("bin/release.rb").to_s.inspect}; print sweep_detect_ruby([])))
    end
    assert status.success?, "could not build the detection snippet: #{err}"

    with_parked_registry do
      # Both carry review's merged:"accepted" stamp, so the ONLY thing that can keep
      # the parked one off the sweep is its ladder.
      parked = task_on("detected", repos: [ LIVE_APP, PARKED_APP ], merged: Task::MERGED_ACCEPTED)
      live   = task_on("detected live", repos: [ LIVE_APP ], merged: Task::MERGED_ACCEPTED)

      out, = capture_io { eval(snippet) } # rubocop:disable Security/Eval
      rows = JSON.parse(out.lines.last)["tasks"]

      assert_equal [ LIVE_APP, PARKED_APP ], rows.find { |r| r["slug"] == parked.slug }&.dig("repos"),
                   "the parked task must reach the CLI with every repo it names"
      plan = Release::SweepPlan.compute(rows, parked: Release::Ladder.parked(Release::Repos.config))
      assert_equal [ parked.slug ], plan["parked"].map { |entry| entry["slug"] }
      assert_equal [ live.slug ], plan["sweep"]
    end
  end

  # --- the auto sweep ------------------------------------------------------------

  test "[integration] curate! leaves a parked task reviewed and unattached while the rest rides" do
    with_parked_registry do
      parked = task_on("curate parked", repos: [ PARKED_APP ])
      mixed  = task_on("curate mixed", repos: [ LIVE_APP, PARKED_APP ])
      live   = task_on("curate live", repos: [ LIVE_APP ])

      release = Release::Conductor.curate!(task_slugs: [])

      assert_equal [ live.slug ], release.tasks.pluck(:slug), "only the live task rides"
      [ parked, mixed ].each do |held|
        held.reload
        assert_equal "reviewed", held.stage
        assert_nil held.release_slug, "#{held.slug} must never be attached to the candidate"
        assert_nil held.merged, "#{held.slug} must not be stamped merged:release"
      end
      refute_includes Release::Conductor.repo_plan(release).map { |g| g[:repo] }, PARKED_APP,
                      "no parked repo reaches the deploy plan"
    end
  end

  # --- the record-time backstop --------------------------------------------------

  test "[unit] validate_members! refuses a member that names a parked repo" do
    with_parked_registry do
      member = task_on("backstop", repos: [ LIVE_APP, PARKED_APP ])
      release = Release::Conductor.sweep!(member)

      error = assert_raises(ArgumentError) { Release::Conductor.validate_members!(release) }

      assert_includes error.message, member.slug
      assert_includes error.message, "#{PARKED_APP} (ladder: dormant)"
    end
  end

  test "[integration] curate! naming a parked task explicitly raises and rolls the candidate back" do
    with_parked_registry do
      parked = task_on("explicit", repos: [ PARKED_APP ])

      assert_raises(ArgumentError) { Release::Conductor.curate!(task_slugs: [ parked.slug ], slug: "rel-parked") }

      assert_equal 0, Release.count, "a refused curation must not strand a half-built candidate"
      assert_equal "reviewed", parked.reload.stage
      assert_nil parked.merged
    end
  end
end

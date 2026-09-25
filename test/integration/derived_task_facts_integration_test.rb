# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "open3"
require "tmpdir"
require_relative "../support/outbound_seams"
require_relative "../support/fake_task_derivation"

# The consumers of TaskDerivedFacts (devops-v3 piece 4a), driven end to end with
# derivation switched ON and GitHub replaced by FakeTaskDerivation:
#
#   * bin/release's detection snippet (run for real against the test DB) hands the
#     plan the DERIVED rung, so a reviewed task whose `merged` stamp never landed
#     still rides the promote;
#   * the multi-repo record check accepts a PR found on the task branch;
#   * reviewer selection and the review-claim backstop exclude a soul whose commits
#     are on the PR even when no stamp names them.
class DerivedTaskFactsIntegrationTest < ActiveSupport::TestCase
  HUB = "mcritchie-studio"
  TURF = "turf-monster"
  HUB_PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/301"
  TURF_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/302"

  def with_derivation(fake, &block)
    TaskDerivedFacts.stub(:enabled?, true) do
      Github::TaskDerivation.stub(:new, fake, &block)
    end
  end

  def release_snippet(expr)
    out, err, status = Dir.mktmpdir("derived-facts-locks") do |locks|
      Open3.capture3(OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => locks), RbConfig.ruby, "-e",
                     %(load #{Rails.root.join("bin/release.rb").to_s.inspect}; print #{expr}))
    end
    assert status.success?, "could not build the snippet: #{err}"
    out
  end

  def eval_rows(snippet)
    out, = capture_io { eval(snippet) } # rubocop:disable Security/Eval
    JSON.parse(out.lines.last)
  end

  test "[integration] prepare's detection snippet reads the derived rung, so an unstamped task is promoted" do
    snippet = release_snippet("sweep_detect_ruby([])")
    lost = Task.create!(title: "derived rung lost stamp task", stage: "reviewed", merged: nil,
                        metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB], "pr_url" => HUB_PR } })

    # Stamps alone: the row reads merged:"" and the plan HOLDS it.
    stamped_rows = eval_rows(snippet)["tasks"]
    assert_equal "", stamped_rows.find { |r| r["slug"] == lost.slug }["merged"]

    rows = with_derivation(FakeTaskDerivation.new(rungs: { HUB_PR => "accepted" })) { eval_rows(snippet)["tasks"] }
    row = rows.find { |r| r["slug"] == lost.slug }
    assert_equal "accepted", row["merged"], "GitHub places the merge commit on accepted"

    plan = Release::SweepPlan.compute(rows)
    assert_includes plan["sweep"], lost.slug, "the derived rung puts the task on the promote"
  end

  test "[integration] the merge resolve snippet and the stranded-commit index read the derived rung too" do
    t = Task.create!(title: "derived rung resolve task", stage: "reviewed", merged: Task::MERGED_ACCEPTED,
                     metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB], "pr_url" => HUB_PR } })
    fake = FakeTaskDerivation.new(rungs: { HUB_PR => "release" })

    resolved = with_derivation(fake) { eval_rows(release_snippet("batch_resolve_ruby([#{t.slug.inspect}])")) }
    assert_equal "release", resolved["tasks"].first["merged"]

    # stranded_task_index hands its snippet to `conductor`; capture it there.
    index_snippet = release_snippet(<<~RUBY.squish)
      begin; def conductor(code, **); print code; $stdout.flush; exit!(0); end;
      stranded_task_index({ "#{HUB}" => [{ "sha" => "abc",
      "subject" => "Merge pull request #301 from McRitchie-Studio/feat/#{t.slug}" }] }); end
    RUBY
    index = with_derivation(fake) { eval_rows(index_snippet)["tasks"] }
    assert_equal "release", index.dig(t.slug, "merged")
  end

  test "[integration] the multi-repo record check accepts a PR derived from the task branch" do
    t = Task.create!(title: "derived pr record task", stage: "reviewed",
                     metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB, TURF], "pr_url" => HUB_PR } })
    release = Release::Conductor.sweep!(t)

    assert_raises(ArgumentError) { Release::Conductor.validate_members!(release.reload) }

    fake = FakeTaskDerivation.new(branches: { [TURF, "feat/#{t.slug}"] => TURF_PR })
    with_derivation(fake) { Release::Conductor.validate_members!(release.reload) }
  end

  test "[integration] reviewer selection excludes a soul whose commits are on the PR" do
    t = Task.create!(title: "derived authors selection task", stage: "submitted",
                     metadata: { "devops" => { "shape" => "ui-only", "repositories" => [HUB], "pr_url" => HUB_PR,
                                               "built_by" => "mack" } })

    stamped = ReviewerSelector.new(t).decision
    assert_equal %w[mack], stamped["builders"]

    derived = with_derivation(FakeTaskDerivation.new(authors: { HUB_PR => %w[shannon] })) do
      ReviewerSelector.new(Task.find(t.id)).decision
    end
    assert_equal %w[mack shannon], derived["builders"], "the PR's commit author joins the stamp"
    refute_includes derived["reviewers"].map { |r| r["slug"] }, "shannon", "a PR author is never seated"

    injected = ReviewerSelector.new(t, pr_authors: %w[shannon]).decision
    assert_equal %w[mack shannon], injected["builders"]
  end

  test "[integration] the review-claim backstop refuses a PR author no stamp names" do
    t = Task.create!(title: "derived authors claim task", stage: "submitted",
                     metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB], "pr_url" => HUB_PR,
                                               "built_by" => "mack" } })

    refute TaskReviewClaim.self_review?(t.slug, "jasper")
    with_derivation(FakeTaskDerivation.new(authors: { HUB_PR => %w[jasper] })) do
      assert TaskReviewClaim.self_review?(t.slug, "jasper")
      assert TaskReviewClaim.self_review?(t.slug, "mack"), "the stamp still counts"
    end
  end

  test "[integration] prepare's detection snippet asks GitHub once per task fact, not once per reader" do
    snippet = release_snippet("sweep_detect_ruby([])")
    t = Task.create!(title: "derived bounded calls task", stage: "reviewed", merged: nil,
                     metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB] } })
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => HUB_PR }, rungs: { HUB_PR => "accepted" })

    row = with_derivation(fake) { eval_rows(snippet)["tasks"] }.find { |r| r["slug"] == t.slug }
    assert_equal "accepted", row["merged"]
    assert_equal HUB_PR, row["pr_url"]

    mine = fake.calls.select { |c| c.include?("feat/#{t.slug}") || c.include?(HUB_PR) }
    assert_equal 1, mine.count { |c| c.first == :pr_url_for_branch }, "the branch lookup is asked once"
    assert_equal 1, mine.count { |c| c.first == :merged_rung }, "the rung is asked once"
  end
end

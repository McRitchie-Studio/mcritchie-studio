# frozen_string_literal: true

require "test_helper"
require_relative "../support/fake_task_derivation"

# TaskDerivedFacts (devops-v3 piece 4a): the merged rung, PR url and author set
# derived from GitHub, each falling back to its hand-written stamp for one release.
class TaskDerivedFactsTest < ActiveSupport::TestCase
  HUB = "mcritchie-studio"
  TURF = "turf-monster"
  HUB_PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/101"
  TURF_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/202"

  def task(merged: nil, devops: {})
    Task.create!(title: "derived facts sample task", stage: "reviewed", merged: merged,
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB] }.merge(devops) })
  end

  # --- merged rung -----------------------------------------------------------------

  test "[unit] the derived rung wins over a stale stamp" do
    t = task(merged: Task::MERGED_ACCEPTED, devops: { "pr_url" => HUB_PR })
    assert_equal "release", t.merged_rung(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => "release" }))
  end

  test "[unit] an unplaced PR keeps the stamp, so bin/task merged still overrides" do
    t = task(merged: Task::MERGED_ACCEPTED, devops: { "pr_url" => HUB_PR })
    assert_equal "accepted", t.merged_rung(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => nil }))
    assert_nil task(devops: { "pr_url" => HUB_PR }).merged_rung(derivation: FakeTaskDerivation.new)
  end

  test "[unit] an unreadable rung falls back to the stamp, never to nil" do
    t = task(merged: Task::MERGED_RELEASE, devops: { "pr_url" => HUB_PR })
    assert_equal "release", t.merged_rung(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => :unreadable }))
  end

  test "[unit] with derivation switched off (the test default) the reader is the stamp and asks nothing" do
    t = task(merged: Task::MERGED_MAIN, devops: { "pr_url" => HUB_PR })
    assert_nil t.github_derivation
    assert_equal "main", t.merged_rung
  end

  test "[unit] a multi-repo task sits on its LOWEST rung, and an unmerged repo defers to the stamp" do
    devops = { "repositories" => [HUB, TURF], "pr_url" => HUB_PR, "pr_urls" => { TURF => TURF_PR } }
    t = task(merged: Task::MERGED_ACCEPTED, devops: devops)

    assert_equal "release", t.merged_rung(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => "main", TURF_PR => "release" }))
    assert_equal "accepted", t.merged_rung(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => "main", TURF_PR => nil }))
  end

  test "[unit] an unrecorded PR is found by branch and then placed" do
    t = task
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => HUB_PR }, rungs: { HUB_PR => "accepted" })
    assert_equal "accepted", t.merged_rung(derivation: fake)
  end

  test "[unit] refresh_merged_rung! caches the derived rung and never clears a stamp" do
    t = task(merged: Task::MERGED_ACCEPTED, devops: { "pr_url" => HUB_PR })
    assert_equal "main", t.refresh_merged_rung!(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => "main" }))
    assert_equal "main", t.reload.merged

    assert_equal "main", t.refresh_merged_rung!(derivation: FakeTaskDerivation.new(rungs: { HUB_PR => :unreadable }))
    assert_equal "main", t.reload.merged
  end

  # THE AGREEMENT TABLE: for every rung a stamp can hold, a fixture whose PR GitHub
  # places on that same rung reads the same value derived as stamped. When 4b deletes
  # the stamp, this is the table that says nothing a guard reads will change.
  test "[unit] derived and stamped rungs agree on fixtures at every rung" do
    Task::MERGED_STATES.each_with_index do |rung, i|
      url = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/#{900 + i}"
      t = task(merged: rung, devops: { "pr_url" => url })
      fake = FakeTaskDerivation.new(rungs: { url => rung })

      assert_equal t.merged, t.derived_merged_rung(derivation: fake), "stamp #{rung} vs derived"
      assert_equal t.merged, t.merged_rung(derivation: fake)
    end
  end

  # --- PR url -------------------------------------------------------------------------

  test "[unit] a recorded PR url wins without asking GitHub" do
    fake = FakeTaskDerivation.new
    assert_equal HUB_PR, task(devops: { "pr_url" => HUB_PR }).pr_url_or_derived(derivation: fake)
    assert_empty fake.calls
  end

  test "[unit] a blank PR url derives from the recorded branch, else feat/<slug>" do
    t = task(devops: { "branch" => "feat/custom-branch" })
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/custom-branch"] => HUB_PR })
    assert_equal HUB_PR, t.pr_url_or_derived(derivation: fake)

    plain = task
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{plain.slug}"] => HUB_PR })
    assert_equal HUB_PR, plain.pr_url_or_derived(derivation: fake)
    assert_nil task.pr_url_or_derived(derivation: FakeTaskDerivation.new(branches: { [HUB, "x"] => :unreadable }))
  end

  test "[unit] an abandoned PR is never derived back" do
    t = task(devops: { "abandoned_prs" => ["#{HUB_PR} superseded by a rebuild"] })
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => HUB_PR })
    assert_nil t.pr_url_or_derived(derivation: fake)
  end

  test "[unit] derived release PR urls fill only the gaps, and an unreadable gap stays a gap" do
    t = task(devops: { "repositories" => [HUB, TURF], "pr_url" => HUB_PR })
    branch = "feat/#{t.slug}"

    filled = t.derived_release_pr_urls(derivation: FakeTaskDerivation.new(branches: { [TURF, branch] => TURF_PR,
                                                                                         [HUB, branch] => "WRONG" }))
    assert_equal({ HUB => HUB_PR, TURF => TURF_PR }, filled, "the recorded hub url wins; turf is filled")

    gap = t.derived_release_pr_urls(derivation: FakeTaskDerivation.new(branches: { [TURF, branch] => :unreadable }))
    assert_equal({ HUB => HUB_PR }, gap)
  end

  # --- authors ------------------------------------------------------------------------

  test "[unit] derived authors union every PR, and an unreadable PR contributes nobody" do
    t = task(devops: { "repositories" => [HUB, TURF], "pr_url" => HUB_PR, "pr_urls" => { TURF => TURF_PR } })
    fake = FakeTaskDerivation.new(authors: { HUB_PR => %w[mack steffon], TURF_PR => %w[steffon jasper] })
    assert_equal %w[jasper mack steffon], t.derived_authors(derivation: fake).sort

    fake = FakeTaskDerivation.new(authors: { HUB_PR => %w[mack], TURF_PR => :unreadable })
    assert_equal %w[mack], task(devops: t.devops).derived_authors(derivation: fake)
  end

  test "[unit] with derivation off there are no derived authors" do
    assert_equal [], task(devops: { "pr_url" => HUB_PR }).derived_authors
  end

  # --- bounded reads (harden-derived-fact-reads) ---------------------------------------

  test "[unit] one task row asks for its branch PR and its rung once, however many readers" do
    t = task
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => HUB_PR }, rungs: { HUB_PR => "accepted" })

    t.merged_rung(derivation: fake)
    t.pr_url_or_derived(derivation: fake)
    t.derived_release_pr_urls(derivation: fake)
    t.merged_rung(derivation: fake)

    assert_equal 1, fake.calls.count { |c| c.first == :pr_url_for_branch }
    assert_equal 1, fake.calls.count { |c| c.first == :merged_rung }
  end

  test "[unit] the derived PR memo is keyed on the abandoned list and the branch" do
    t = task
    fake = FakeTaskDerivation.new(branches: { [HUB, "feat/#{t.slug}"] => HUB_PR, [HUB, "feat/renamed"] => TURF_PR })
    assert_equal HUB_PR, t.derived_pr_url(derivation: fake)

    t.metadata["devops"]["abandoned_prs"] = ["#{HUB_PR} superseded"]
    assert_nil t.derived_pr_url(derivation: fake), "a newly abandoned PR is not served from the memo"

    t.metadata["devops"]["branch"] = "feat/renamed"
    assert_equal TURF_PR, t.derived_pr_url(derivation: fake), "a changed branch is not served from the memo"
  end

  test "[unit] every task in a process shares the default derivation" do
    Github::TaskDerivation.reset_shared!
    TaskDerivedFacts.stub(:enabled?, true) do
      assert_same task.github_derivation, task.github_derivation
    end
  ensure
    Github::TaskDerivation.reset_shared!
  end
end

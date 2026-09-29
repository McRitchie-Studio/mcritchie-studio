# frozen_string_literal: true

require "test_helper"

# [unit] One claim pays for at most one generator call: the job is never
# retried, and a run that no longer holds its build returns before the call.
class SheetBuildJobTest < ActiveJob::TestCase
  setup do
    Appearance.delete_all
    @look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Bills home")
    @started_at = Appearances::SheetBuild.claim!(@look)
  end

  test "a failing build is recorded, not raised, and not retried" do
    Appearances::GenerateArtifact.stub(:call, ->(*, **) { raise "boom" }) do
      assert_nothing_raised { SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6)) }
    end

    assert_equal %w[failed boom], @look.reload.values_at(:sheet_build_state, :sheet_build_error)
    assert_no_enqueued_jobs only: SheetBuildJob
  end

  test "the typed number reaches the generator" do
    seen = nil
    Appearances::GenerateArtifact.stub(:call, ->(_look, number:) { seen = number }) do
      SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6), "17")
    end

    assert_equal "17", seen
    assert_equal "done", @look.reload.sheet_build_state
  end

  test "a look deleted before the job runs is a no-op" do
    @look.destroy!

    assert_nothing_raised { SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6)) }
  end

  test "a job whose build no longer matches returns before the generator" do
    @look.update_columns(sheet_build_started_at: @started_at - 1.minute)
    called = false

    Appearances::GenerateArtifact.stub(:call, ->(*, **) { called = true }) do
      SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6))
    end

    assert_not called
    assert_equal "building", @look.reload.sheet_build_state
  end

  test "running the same job twice calls the generator once" do
    calls = 0
    Appearances::GenerateArtifact.stub(:call, ->(*, **) { calls += 1 }) do
      2.times { SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6)) }
    end

    assert_equal 1, calls
  end

  # A restart re-runs the job while the first run is still mid-call.
  test "a re-run while the first run is mid-call spends nothing" do
    calls = 0
    rerun = -> { SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6)) }
    Appearances::GenerateArtifact.stub(:call, ->(*, **) { calls += 1; rerun.call if calls == 1 }) do
      rerun.call
    end

    assert_equal 1, calls
    assert_equal "done", @look.reload.sheet_build_state
  end

  test "a job left behind after a stale reclaim spends nothing" do
    @look.update_columns(sheet_build_started_at: (Appearances::SheetBuild::STALE_AFTER + 1.minute).ago)
    old = @look.reload.sheet_build_started_at
    Appearances::SheetBuild.claim!(@look)
    called = false

    Appearances::GenerateArtifact.stub(:call, ->(*, **) { called = true }) do
      SheetBuildJob.perform_now(@look.slug, old.iso8601(6))
    end

    assert_not called
  end

  # The stale window counts from when the job runs, not from the claim.
  test "the stale window restarts when the job begins running" do
    stale_mid_call = nil
    travel 10.minutes do
      Appearances::GenerateArtifact.stub(:call, ->(look, **) { travel(6.minutes); stale_mid_call = look.reload.sheet_build_stale? }) do
        SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6))
      end
    end

    assert_equal false, stale_mid_call
  end
end

# frozen_string_literal: true

require "test_helper"

# [unit] The job records the outcome and never raises, so ApplicationJob's
# retry_on cannot turn one press into a second paid call.
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
end

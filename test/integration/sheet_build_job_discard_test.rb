# frozen_string_literal: true

require "test_helper"

# [integration] SheetBuildJob is discarded on any error: ApplicationJob's
# retry_on must not re-run it into a second paid call.
class SheetBuildJobDiscardTest < ActiveJob::TestCase
  setup do
    Appearance.delete_all
    @look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Bills home")
    @started_at = Appearances::SheetBuild.claim!(@look)
  end

  test "an error inside the job's own error handling is discarded, not retried" do
    calls = 0
    Appearances::GenerateArtifact.stub(:call, ->(*, **) { calls += 1; raise "vendor 500" }) do
      ErrorLog.stub(:capture!, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db gone" }) do
        assert_nothing_raised { SheetBuildJob.perform_now(@look.slug, @started_at.iso8601(6)) }
      end
    end

    assert_equal 1, calls
    assert_no_enqueued_jobs only: SheetBuildJob
  end

  test "the job discards StandardError ahead of ApplicationJob's retry_on" do
    job = SheetBuildJob.new(@look.slug, @started_at.iso8601(6))
    error = RuntimeError.new("x")

    assert_no_enqueued_jobs(only: SheetBuildJob) { job.handler_for_rescue(error).call(error) }
  end
end

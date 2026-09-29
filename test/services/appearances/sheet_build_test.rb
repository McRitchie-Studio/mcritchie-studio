# frozen_string_literal: true

require "test_helper"

# [unit] The sheet-build guard: one paid build per look at a time, a crashed
# build goes stale rather than locking the look, and the job's outcome is
# recorded. GenerateArtifact is stubbed; nothing is spent.
class Appearances::SheetBuildTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  Ready = Struct.new(:x) { def check! = nil }
  Refusing = Struct.new(:x) { def check! = raise(Appearances::GenerateArtifact::NoIdentityPhoto, "no face") }

  setup do
    Appearance.delete_all
    @look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Bills home")
  end

  test "a claim marks the look building" do
    started_at = Appearances::SheetBuild.claim!(@look)

    @look.reload
    assert_equal "building", @look.sheet_build_state
    assert_equal started_at, @look.sheet_build_started_at
    assert_nil @look.sheet_build_finished_at
    assert @look.sheet_building?
  end

  test "a second claim is refused while one is building" do
    Appearances::SheetBuild.claim!(@look)

    assert_raises(Appearances::SheetBuild::Busy) { Appearances::SheetBuild.claim!(@look) }
  end

  # The guard reads the row, not the caller's copy: a second request holding a
  # look loaded before the first claim is still refused.
  test "a claim is refused through a stale in-memory copy" do
    stale_copy = Appearance.find(@look.id)
    Appearances::SheetBuild.claim!(@look)

    assert_nil stale_copy.sheet_build_state
    assert_raises(Appearances::SheetBuild::Busy) { Appearances::SheetBuild.claim!(stale_copy) }
  end

  test "a building older than the timeout is stale and can be claimed again" do
    @look.update_columns(sheet_build_state: "building",
                         sheet_build_started_at: (Appearances::SheetBuild::STALE_AFTER + 1.minute).ago)

    assert @look.reload.sheet_build_stale?
    assert_not @look.sheet_building?
    started_at = Appearances::SheetBuild.claim!(@look)
    assert_in_delta Time.current, started_at, 5
  end

  test "a failed or done build can be claimed again" do
    %w[failed done].each do |state|
      @look.update_columns(sheet_build_state: state, sheet_build_started_at: 1.minute.ago)
      assert_nothing_raised { Appearances::SheetBuild.claim!(@look) }
    end
  end

  test "start refuses a look that cannot be built, before claiming or enqueueing" do
    Appearances::GenerateArtifact.stub(:new, Refusing.new) do
      assert_raises(Appearances::GenerateArtifact::NoIdentityPhoto) { Appearances::SheetBuild.start!(@look) }
    end
    assert_nil @look.reload.sheet_build_state
    assert_no_enqueued_jobs
  end

  test "start claims and enqueues exactly one job; a second start enqueues none" do
    Appearances::GenerateArtifact.stub(:new, Ready.new) do
      Appearances::SheetBuild.start!(@look, number: "17")
      assert_raises(Appearances::SheetBuild::Busy) { Appearances::SheetBuild.start!(@look) }
    end

    assert_enqueued_jobs 1, only: SheetBuildJob
    assert_equal "building", @look.reload.sheet_build_state
  end

  test "run records done when the generator returns" do
    started_at = Appearances::SheetBuild.claim!(@look)

    Appearances::GenerateArtifact.stub(:call, :artifact) do
      Appearances::SheetBuild.run(@look, started_at: started_at)
    end

    @look.reload
    assert_equal "done", @look.sheet_build_state
    assert_not_nil @look.sheet_build_finished_at
    assert_nil @look.sheet_build_error
  end

  test "run records failed with the reason and logs an unexpected error" do
    started_at = Appearances::SheetBuild.claim!(@look)

    assert_difference -> { ErrorLog.count }, 1 do
      Appearances::GenerateArtifact.stub(:call, ->(*, **) { raise ImageGeneration::GenerationFailed, "vendor 500" }) do
        Appearances::SheetBuild.run(@look, started_at: started_at)
      end
    end

    @look.reload
    assert_equal "failed", @look.sheet_build_state
    assert_equal "vendor 500", @look.sheet_build_error
  end

  test "run records an expected refusal as failed without an ErrorLog row" do
    started_at = Appearances::SheetBuild.claim!(@look)

    assert_no_difference -> { ErrorLog.count } do
      Appearances::GenerateArtifact.stub(:call, ->(*, **) { raise Appearances::GenerateArtifact::NoGenerator, "set OPENAI_API_KEY" }) do
        Appearances::SheetBuild.run(@look, started_at: started_at)
      end
    end

    assert_equal ["failed", "set OPENAI_API_KEY"], @look.reload.values_at(:sheet_build_state, :sheet_build_error)
  end

  # A stale build that finishes late must not overwrite the build that replaced it.
  test "a superseded run does not overwrite the newer build's state" do
    Appearances::SheetBuild.claim!(@look)
    @look.update_columns(sheet_build_started_at: (Appearances::SheetBuild::STALE_AFTER + 1.minute).ago)
    old = @look.reload.sheet_build_started_at
    Appearances::SheetBuild.claim!(@look)

    Appearances::GenerateArtifact.stub(:call, :artifact) do
      Appearances::SheetBuild.run(@look, started_at: old)
    end

    assert_equal "building", @look.reload.sheet_build_state
  end
end

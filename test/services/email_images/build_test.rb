# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] The build guard on the brief: one paid round at a time, run once, a
# crashed round goes stale rather than locking the brief, and the round cap is
# enforced in the same conditional UPDATE as the claim.
class EmailImages::BuildTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    @brief = turf_brief
  end

  test "a claim marks the brief building and spends a round" do
    started_at = EmailImages::Build.claim!(@brief)

    @brief.reload
    assert_equal "building", @brief.build_state
    assert_equal started_at, @brief.build_started_at
    assert_equal 1, @brief.rounds_used
    assert_predicate @brief, :building?
  end

  test "a second claim is refused while one is building, and spends nothing" do
    EmailImages::Build.claim!(@brief)

    assert_raises(EmailImages::Build::Busy) { EmailImages::Build.claim!(EmailImageBrief.find(@brief.id)) }
    assert_equal 1, @brief.reload.rounds_used
  end

  test "a stale build can be claimed again" do
    @brief.update_columns(build_state: "building", build_started_at: (EmailImages::Build::STALE_AFTER + 1.minute).ago)

    assert_predicate @brief.reload, :build_stale?
    assert_nothing_raised { EmailImages::Build.claim!(@brief) }
  end

  test "no claim past the round limit" do
    @brief.update_columns(rounds_used: 4, max_rounds: 4)

    error = assert_raises(EmailImages::Build::Busy) { EmailImages::Build.claim!(@brief) }
    assert_includes error.message, "all 4 rounds"
  end

  # THE RUN-ONCE GUARANTEE. The job takes the claim before the paid call, so a
  # re-run of the same job (a restart, a duplicate enqueue) spends nothing.
  test "the same claim runs once: a second run of the job spends nothing" do
    with_fake_header_generator do
      started_at = EmailImages::Build.claim!(@brief)
      EmailImages::Build.run(@brief, started_at: started_at)
      EmailImages::Build.run(@brief, started_at: started_at)

      assert_equal 2, EmailImageFakes::Adapter.calls.size, "one round = two paid calls, never four"
      assert_equal 2, @brief.candidates.count
      assert_equal "done", @brief.reload.build_state
    end
  end

  test "a superseded build cannot finish its replacement" do
    first = EmailImages::Build.claim!(@brief)
    @brief.update_columns(build_started_at: (EmailImages::Build::STALE_AFTER + 1.minute).ago)
    stale_token = @brief.reload.build_started_at
    second = EmailImages::Build.claim!(@brief)

    assert_nil EmailImages::Build.take(@brief, stale_token)
    assert_nil EmailImages::Build.take(@brief, first)
    assert EmailImages::Build.take(@brief, second)
  end

  class RefusingAdapter
    def self.new(_row) = allocate
    def generate_and_wait(**) = raise(ImageGeneration::GenerationFailed, "vendor said no")
  end

  test "a failed round records the reason and frees the brief" do
    ImageGeneration::Adapter.stub(:for, RefusingAdapter) do
      with_env("OPENAI_API_KEY", "sk-test") do
        started_at = EmailImages::Build.claim!(@brief)
        EmailImages::Build.run(@brief, started_at: started_at)
      end
    end

    @brief.reload
    assert_equal "failed", @brief.build_state
    assert_includes @brief.build_error, "vendor said no"
    assert_not @brief.building?
  end

  test "start! refuses for free when no generator is configured" do
    with_env("OPENAI_API_KEY", nil) do
      assert_raises(EmailImages::Generate::NoGenerator) { EmailImages::Build.start!(@brief) }
    end
    assert_nil @brief.reload.build_state
    assert_equal 0, @brief.rounds_used
    assert_no_enqueued_jobs only: EmailImageBuildJob
  end

  test "start! claims and enqueues the job once" do
    with_env("OPENAI_API_KEY", "sk-test") do
      assert_enqueued_jobs 1, only: EmailImageBuildJob do
        EmailImages::Build.start!(@brief)
      end
    end
  end

  test "the job discards errors rather than retrying a paid call" do
    assert_includes EmailImageBuildJob.rescue_handlers.map(&:first), "StandardError"
  end

  test "start! hands the round's notes to the job, which hands them to the prompt" do
    with_env("OPENAI_API_KEY", "sk-test") do
      EmailImages::Build.start!(@brief, notes: "  sunrise  ")
    end
    job = enqueued_jobs.find { |j| j["job_class"] == "EmailImageBuildJob" }
    assert_equal "sunrise", job["arguments"].last

    with_fake_header_generator do
      perform_enqueued_jobs(only: EmailImageBuildJob)
    end
    assert(@brief.candidates.all? { |a| a.prompt.include?("Round 1 direction: sunrise") })
  end

  test "run_now! runs the round in-process under the same claim" do
    with_fake_header_generator do
      EmailImages::Build.run_now!(@brief, notes: "dusk")
    end

    assert_equal "done", @brief.reload.build_state
    assert_equal 1, @brief.rounds_used
    assert_equal 2, @brief.candidates.count
    assert_no_enqueued_jobs only: EmailImageBuildJob
  end
end

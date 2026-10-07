# frozen_string_literal: true

# Guard catalog row 1.6, the construction that replaced the executed-set gate's
# "CHECKOUT RACE" refusal: the Rails lane's plan, every shard and the executed-set gate
# check out ONE commit, `github.sha`, so the gate can never audit receipts from a
# different tree than the one it re-derives the expected set from. Run directly:
#   ruby -Itest test/lib/rails_lane_checkout_pin_test.rb

require "minitest/autorun"
require "yaml"

class RailsLaneCheckoutPinTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/ci.yml", __dir__)
  LANE_JOBS = %w[rails_plan rails rails_executed_set].freeze

  def test_every_rails_lane_job_checks_out_github_sha
    jobs = YAML.load_file(WORKFLOW).fetch("jobs")

    LANE_JOBS.each do |job|
      checkouts = jobs.fetch(job).fetch("steps").select { |step| step["uses"].to_s.start_with?("actions/checkout") }

      assert_equal 1, checkouts.size, "#{job}: one checkout"
      assert_equal "${{ github.sha }}", checkouts.first.dig("with", "ref"),
                   "#{job} must check out github.sha, or the executed-set gate can read a different tree"
    end
  end
end

# frozen_string_literal: true

require "test_helper"

# Dependency updates are reactive, not scheduled (ruling 2026-11-10, task
# ci-runs-reactive-and-once): a bump starts from the dependency-update SOP
# (docs/agents/modules/dependency-update.md). Security updates are a repository
# setting, not this file. Bringing the file back deletes this test on purpose.
class ScheduledDependabotOffTest < ActiveSupport::TestCase
  test "[unit] no scheduled Dependabot version updates" do
    path = Rails.root.join(".github", "dependabot.yml")
    assert_not File.exist?(path),
      "#{path} exists. Scheduled version updates are off by ruling (task " \
      "ci-runs-reactive-and-once); run the dependency-update SOP instead, or delete " \
      "this test on purpose"
  end
end

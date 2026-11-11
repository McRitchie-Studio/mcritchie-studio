# frozen_string_literal: true

require "yaml"

# QaOnMerge — a reviewed merge starts a QA release for that task, with no batch wait
# (task release-sub-hour-pipeline). Measured on rel-20261110-0123f9: about an hour of
# the 15-minute task's path to production was reviewed cards waiting on `accepted`
# for someone to start a release.
#
# OPT-IN, and it stops at QA. When enabled, bin/pr-review starts
# `bin/release qa-on-merge <slug>` in the background right after it merges a task
# into `accepted`; that command runs `bin/release prepare --task <slug> --yes` only
# when no release is active (an active release means a sweep is already in flight,
# and the task rides the next one). prepare ends at `assembled` on QA. Production
# still takes Alex McRitchie's own clearance (`bin/release cycle --clearance …` or
# `bin/release ship --mode cleared`): nothing here ships.
#
# The switch: RELEASE_QA_ON_MERGE in the environment (1/on/true or 0/off/false) wins;
# otherwise config/release_builder.yml `qa_on_merge.enabled` (default false).
module QaOnMerge
  CONFIG_PATH = File.expand_path("../../config/release_builder.yml", __dir__)
  ENV_FLAG = "RELEASE_QA_ON_MERGE"
  ON = %w[1 on true yes].freeze
  OFF = %w[0 off false no].freeze

  module_function

  # Is the trigger on? The env flag wins; an unreadable config is off.
  def enabled?(env: ENV, config_path: CONFIG_PATH)
    flag = env[ENV_FLAG].to_s.strip.downcase
    return true if ON.include?(flag)
    return false if OFF.include?(flag)

    config = YAML.safe_load(File.read(config_path))
    config.is_a?(Hash) && config.dig("qa_on_merge", "enabled") == true
  rescue StandardError
    false
  end

  # PURE. [:launch, argv] to start the QA release, or [:skip, reason].
  # +active+ is the active release's slug ("" or nil when none).
  def decide(slug:, enabled:, active:)
    slug = slug.to_s.strip
    return [:skip, "no task slug given"] if slug.empty?
    return [:skip, "off (#{ENV_FLAG} or config/release_builder.yml qa_on_merge.enabled)"] unless enabled
    return [:skip, "release #{active} is active; #{slug} rides the next release"] unless active.to_s.strip.empty?

    [:launch, prepare_argv(slug)]
  end

  def prepare_argv(slug) = ["prepare", "--task", slug.to_s, "--yes"]
end

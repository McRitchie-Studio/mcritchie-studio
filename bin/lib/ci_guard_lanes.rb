# frozen_string_literal: true

# CiGuardLanes: the whole-tree guards CI runs that bin/fast-check's diff mapping
# never selects, picked by what the diff touches.
#
# fast-check maps each changed file to its own tests. A guard that reads EVERY
# template, or the whole e2e/ suite, is nobody's twin, so a diff that broke one went
# green locally and red on the PR. Three such guards cost a full CI cycle each over
# the 2026-10-10/11 weekend:
#
#   template-ratchets  test/views/inline_script_and_x_data_ratchet_test.rb (the
#                      inline <script> / x-data ratchet) and
#                      test/views/status_colour_tokens_test.rb (no fixed Tailwind
#                      status palette). Both run in CI's Rails lane.
#   e2e-census         bin/e2e-census-check (Playwright's own --list against the
#                      source census bin/e2e-executed-set-check counts by) and the
#                      static guard test/lib/e2e_quarantine_ratchet_test.rb.
#
# The guards run as CI runs them, over the whole tree; only the CHOICE of guard
# reads the diff. A guard whose files this checkout does not carry (a satellite
# desk) is not selected.
module CiGuardLanes
  Guard = Struct.new(:label, :triggers, :tests, :scripts, keyword_init: true) do
    def triggered_by?(changed) = changed.any? { |path| triggers.any? { |pattern| path.match?(pattern) } }
  end

  GUARDS = [
    Guard.new(
      label: "template-ratchets",
      triggers: [%r{\Aapp/(?:views|components|helpers)/},
                 %r{\Atest/views/(?:inline_script_and_x_data_(?:ratchet_test\.rb|pins\.yml)|status_colour_tokens_test\.rb)\z}],
      tests: %w[test/views/inline_script_and_x_data_ratchet_test.rb test/views/status_colour_tokens_test.rb],
      scripts: []
    ),
    Guard.new(
      label: "e2e-census",
      triggers: [%r{\Ae2e/}, %r{\Aplaywright\.config\.js\z}, %r{\Aconfig/e2e_lane\.yml\z},
                 %r{\Abin/(?:e2e-|lib/e2e_)}, %r{\Atest/lib/e2e_quarantine_ratchet_test\.rb\z}],
      tests: %w[test/lib/e2e_quarantine_ratchet_test.rb],
      scripts: %w[bin/e2e-census-check]
    )
  ].freeze

  module_function

  # The guards `changed` (repo-relative paths) triggers whose every file exists
  # under `root`.
  def select(changed, root:)
    GUARDS.select do |guard|
      guard.triggered_by?(changed) &&
        (guard.tests + guard.scripts).all? { |path| File.exist?(File.join(root, path)) }
    end
  end

  # The shell command for one guard: its scripts, then its tests under `test_cmd`.
  def command(guard, test_cmd:)
    steps = guard.scripts.dup
    steps << "#{test_cmd} #{guard.tests.join(" ")}" if guard.tests.any?
    steps.join(" && ")
  end
end

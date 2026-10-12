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
#   repo-ratchets      (hub) and turf-ratchets (turf-monster): the cheap whole-repo
#                      ratchets that read every file, so ANY change can trip them.
#                      In the 14 days to 2026-10-12 they were ~30 of 139 failed PR
#                      jobs, each a full CI cycle to learn about; locally they take
#                      ~20s together (test_health 2s, bin_help_flag_class <1s,
#                      fast_cert_subject 6s, citation_resolution_guard 10s, measured
#                      2026-10-12). /tasks/submit-checks-before-push.
#
# The guards run as CI runs them, over the whole tree; only the CHOICE of guard
# reads the diff. A guard whose files this checkout does not carry is not
# selected — which is also how each repo's ratchets stay in their own repo: the
# hub carries none of turf's ratchet files and turf none of the hub's.
module CiGuardLanes
  Guard = Struct.new(:label, :triggers, :tests, :scripts, keyword_init: true) do
    def triggered_by?(changed) = changed.any? { |path| triggers.any? { |pattern| path.match?(pattern) } }
  end

  # A ratchet that reads every file is tripped by any path: a moved line breaks a
  # citation, a new comment a date ceiling.
  ANY_CHANGE = /./

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
    ),
    Guard.new(
      label: "repo-ratchets",
      triggers: [ANY_CHANGE],
      tests: %w[test/lib/test_health_ratchet_test.rb test/lib/bin_help_flag_class_test.rb
                test/lib/fast_cert_subject_test.rb test/docs/citation_resolution_guard_test.rb],
      scripts: []
    ),
    Guard.new(
      label: "turf-ratchets",
      triggers: [ANY_CHANGE],
      tests: %w[test/docs/workflow_citation_docs_test.rb test/lib/dated_comment_attribution_test.rb],
      scripts: []
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

# frozen_string_literal: true

require "yaml"

# CiTestCommand — "what does CI actually run?", read from the repo's OWN
# .github/workflows/ci.yml.
#
# WHY THIS EXISTS. bin/full-suite-check is the CI-INDEPENDENT cert: the route a
# builder takes when CI's verdict is unavailable (rolio's CI can't even be read
# by bin/dor-check today) or too slow to wait for. Its whole selling point is
# "you don't need CI's verdict" — which is a LIE the moment it tests LESS than
# CI. It ran `bin/rails test`, which SKIPS test/system, while every repo's CI
# runs `bin/rails db:test:prepare test test:system`. A builder could take the
# CI-independent route, go green, and have ZERO system coverage.
#
# So the cert lane no longer hard-codes a command it hopes matches CI: it READS
# CI's, from the repo being certified, and runs it VERBATIM. A repo whose CI runs
# something narrower gets that narrower command (the rule is "run what CI runs",
# not "always add test:system"), and a repo with no parseable ci.yml falls back to
# DEFAULT — which still carries the system tier, so the hole can't reopen by
# accident. The same file is the drift guard: change ci.yml and the cert follows;
# a rotted DEFAULT fails test/lib/ci_test_command_test.rb at the seam.
#
# THE COMMAND SHAPE IS LOAD-BEARING — do not "simplify" it.
#   * `bin/rails test test:system` is BROKEN. `test` is a real rails COMMAND, so
#     `test:system` parses as a PATH and the run dies with
#     `LoadError: cannot load such file -- <root>/test:system`.
#   * It works in ci.yml only because the FIRST arg (`db:test:prepare`) is NOT a
#     rails command, which routes the whole line through RAKE — where `test` and
#     `test:system` are two separate tasks. KEEP db:test:prepare FIRST.
#   * That shape also self-prepares its assets: Rails skips its `test:prepare`
#     hook — the one tailwindcss-rails enhances with `tailwindcss:build`, which
#     builds the gitignored app/assets/builds/tailwind.css — whenever an argument
#     looks like a PATH. A rake-routed, path-free line fires the hook for free, so
#     a virgin worktree builds its CSS on demand with no setup step.
module CiTestCommand
  # The fallback when a repo has no parseable ci.yml `test` job. Every Rails repo
  # in the ecosystem (hub, turf-monster, rolio) runs exactly this today; pinned
  # against the hub's real ci.yml by test/lib/ci_test_command_test.rb.
  DEFAULT = "bin/rails db:test:prepare test test:system"

  WORKFLOW = File.join(".github", "workflows", "ci.yml")

  # The single command the repo's ci.yml `test` job runs, or nil when there is
  # none to read. Located by CONTENT (`bin/rails`), not by step name, so renaming
  # the step can't silently blind the resolver.
  #
  # A multi-line `run: |` block is deliberately IGNORED (nil): that is a SCRIPT,
  # and the cert lane runs ONE command string — better to fall back than to run a
  # mangled first line and call it CI's suite.
  def self.for_root(root)
    path = File.join(root.to_s, WORKFLOW)
    return nil unless File.file?(path)

    ci = YAML.safe_load_file(path, aliases: true)
    steps = ci.dig("jobs", "test", "steps")
    return nil unless steps.is_a?(Array)

    run = steps.filter_map { |step| step["run"] if step.is_a?(Hash) }
               .find { |cmd| cmd.to_s.include?("bin/rails") && !cmd.to_s.strip.include?("\n") }
    run&.strip
  rescue StandardError
    nil # an unreadable/odd ci.yml must fall back, never raise inside a cert
  end

  # What the cert lane should run for this repo: CI's command, else the default.
  def self.resolve(root)
    for_root(root) || DEFAULT
  end

  # Does this command run the SYSTEM tier (and therefore need a browser)?
  def self.system_tier?(cmd)
    cmd.to_s.include?("test:system")
  end
end

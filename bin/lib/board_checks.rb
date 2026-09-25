# frozen_string_literal: true

require "json"

# BoardChecks — read a task's devops.checks_run through the board CLI, and verify
# a write to it landed.
#
# bin/control-check records ONE fingerprint-bound line (`[control@<fp>]`) and then
# reads the board back to confirm it persisted: "recorded" is a verified claim,
# never a declaration. These two reads are that discipline.
module BoardChecks
  module_function

  # The task's current checks_run (Array), or nil when the board could not be read.
  #
  # nil is returned for an unreadable/unparseable response AND for a record with no
  # devops hash at all — "I did not find the shape I was looking for" is not
  # evidence of absence. Only a task that genuinely carries devops with no checks
  # yields [], so a bare [] can be trusted to mean "none recorded".
  def fetch(task_bin, slug)
    out = IO.popen([task_bin, "show", slug, "--json"], err: File::NULL, &:read)
    return nil unless $?.success?

    record = JSON.parse(out)
    devops = record.is_a?(Hash) ? record.dig("metadata", "devops") : nil
    return nil unless devops.is_a?(Hash)

    Array(devops["checks_run"])
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # Read checks_run BACK after a write and return the lines from `expected` that did
  # NOT persist — [] when every line landed, nil when the read-back itself failed
  # (UNVERIFIABLE, distinct from a confirmed loss). Counts MULTIPLICITY, not
  # membership: Array#- would report a line as kept when only one of its two copies
  # survived.
  def missing_after_write(task_bin, slug, expected)
    persisted = fetch(task_bin, slug)
    return nil if persisted.nil?

    remaining = persisted.map(&:to_s).tally
    Array(expected).map(&:to_s).each_with_object([]) do |line, lost|
      if remaining.fetch(line, 0).positive?
        remaining[line] -= 1
      else
        lost << line
      end
    end
  end
end

# frozen_string_literal: true

# GUARD (secrets-scrub-follow-ups, 2026-10-24): a script handed to `heroku run …
# bash -c '…'` carries no `$`.
#
# WHY. `heroku run` joins its arguments into ONE string, wraps it in double
# quotes and gives it to the dyno's shell, which expands every `$` before the
# script itself runs. Rehearsed on turf-monster-qa (credential-rotation §2.1):
# `read -r K_NEW && export KEY="$K_NEW"` exported an EMPTY key, because "$K_NEW"
# had expanded to nothing at launch. The working form reads straight into the
# named variable and exports it bare (`read -r KEY && export KEY`), with no `$`.
#
# WHAT COUNTS. One line at a time, backslash continuations joined: a `heroku run`
# whose single-quoted `bash -c`/`sh -c` script contains `$`. A loop that RUNS
# `heroku run` inside a local `sh -c` (no `heroku run` before the `-c`) is not
# this shape.
#
# THE CONTROL. The pattern fires on the pre-fix §2.1 line and stays quiet on its
# fixed form and on the stdin-to-file form docs/email-delivery.md uses.
require "test_helper"

class HerokuRunQuotingGuardTest < ActiveSupport::TestCase
  SCANNED = %w[bin docs RUNBOOK.md README.md].freeze
  EXCLUDED_PREFIXES = %w[docs/agents/archive/].freeze

  def self.offence?(line)
    line.scan(/\bheroku run\b.*?\s--?\s+(?:ba)?sh\s+(?:-[a-z]*\s+)*-[a-z]*c\s+'([^']*)'/).flatten.any? { |s| s.include?("$") }
  end

  def joined_lines(text)
    text.gsub(/\\\n\s*/, " ").each_line.with_index(1)
  end

  test "no heroku run bash -c script in bin/ or docs/ carries a $ the dyno shell would expand" do
    files = Dir.chdir(Rails.root) do
      `git ls-files -- #{SCANNED.join(" ")}`.split("\n")
                                             .reject { |f| EXCLUDED_PREFIXES.any? { |p| f.start_with?(p) } }
                                             .select { |f| File.file?(f) }
    end
    assert(files.any? { |f| f.end_with?("credential-rotation.md") }, "the rotation SOP is not in the scan")

    hits = files.flat_map do |file|
      text = File.read(Rails.root.join(file), encoding: "UTF-8")
      next [] unless text.valid_encoding?

      joined_lines(text).filter_map { |line, n| "#{file}:~#{n}" if self.class.offence?(line) }
    end
    assert_empty hits, "heroku run re-quotes its command in double quotes, so the dyno shell expands " \
                       "these `$` before the script runs (read into the named variable instead): #{hits.join(', ')}"
  end

  test "control: the pre-fix rotation line fires, its fix and the stdin-to-file form stay quiet" do
    before = %(heroku run --no-tty --exit-code --app x -- bash -c 'set -e; read -r K_NEW && export KEY="$K_NEW" && exec bin/rails t')
    after = %(heroku run --no-tty --exit-code --app x -- bash -c 'set -e; read -r KEY && export DRY_RUN=1 KEY && exec bin/rails t')
    file_form = %(heroku run -a cyvasse --no-tty -- bash -c 'cat > /tmp/a.rb; bin/rails runner /tmp/a.rb')
    local_loop = %(nohup sh -c 'while true; do heroku run -a x -- bin/poll; sleep 30; done')

    assert self.class.offence?(before), "the guard is blind to the pre-fix line"
    [after, file_form, local_loop].each { |line| refute self.class.offence?(line), "the guard flags: #{line}" }
  end
end

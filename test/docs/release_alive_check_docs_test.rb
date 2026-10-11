# frozen_string_literal: true

require "test_helper"

# [unit] THE "IS A RELEASE RUNNING?" CHECK THE DOCS PRINT. G4's interrupted-ship
# section told the operator to confirm no ship was alive with
# `ps aux | grep "[r]elease\.rb"`. Once, the shell wrapping that command carried the
# pattern's text too, matched itself, and reported a false hold. The docs now print
# `pgrep -fl 'ruby .*bin/release[.]rb'`: pgrep never lists itself, and the bracketed
# dot keeps the wrapping shell's own command line from matching.
#
# This pins the property, not the sentence: every pgrep pattern an active doc prints
# for bin/release must match a live ship's command line and none of the look-alikes.
class ReleaseAliveCheckDocsTest < ActiveSupport::TestCase
  DOCS = Rails.root.join("docs/agents")
  PRINTED = /pgrep -f\w* '(?<pattern>[^']*bin\/release[^']*)'/

  LIVE = [
    "/opt/homebrew/opt/ruby@3.3/bin/ruby /Users/alex/projects/mcritchie-studio/bin/release.rb ship --yes",
    "/Users/alex/.local/share/mise/installs/ruby/3.3.11/bin/ruby /Users/alex/projects/mcritchie-studio/bin/release.rb prepare --yes"
  ].freeze
  LOOK_ALIKES = [
    "/bin/zsh -c pgrep -fl 'ruby .*bin/release[.]rb'",
    "/bin/zsh -c ps aux | grep \"[r]elease\\.rb\"",
    "/opt/homebrew/opt/ruby@3.3/bin/ruby /Users/alex/projects/mcritchie-studio/bin/release-check",
    "/bin/sh /Users/alex/projects/mcritchie-studio/bin/release status"
  ].freeze

  def active_docs = Dir[DOCS.join("**/*.md")].reject { |path| path.include?("/archive/") }

  def printed_patterns
    active_docs.flat_map { |path| File.read(path).scan(PRINTED).flatten.map { |pattern| [path, pattern] } }
  end

  test "the G4 ship gate prints the pgrep check" do
    assert_includes DOCS.join("modules/gates/g4-ship.md").read, "pgrep -fl 'ruby .*bin/release[.]rb'"
  end

  test "every printed release check finds a live ship and none of its look-alikes" do
    assert_operator printed_patterns.size, :>=, 2, "the G4 gate and archive-shipped both print one"
    printed_patterns.each do |path, pattern|
      regex = Regexp.new(pattern)
      LIVE.each { |line| assert_match regex, line, "#{path}: #{pattern} misses a live ship" }
      LOOK_ALIKES.each { |line| refute_match regex, line, "#{path}: #{pattern} matches #{line}" }
    end
  end

  test "no active doc prints the self-matching ps-and-grep check" do
    offenders = active_docs.select { |path| File.read(path).match?(/grep\s+"\[r\]elease/) }

    assert_empty offenders
  end
end

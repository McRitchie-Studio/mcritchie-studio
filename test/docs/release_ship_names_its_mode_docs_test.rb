# frozen_string_literal: true

require "test_helper"

# [unit] A DOC NEVER TEACHES A BARE `bin/release ship --yes`. With no `--mode`,
# ShipAuthority.resolve_mode turns `--yes` into `auto`: the ship asks nobody and
# records no clearance on the release. First Rule 5 says a production ship runs as
# `--mode cleared --clearance "<Alex McRitchie's words>"` (or `bin/release cycle
# --clearance`), and `--mode timed` is for a ship nobody cleared. The heartbeat
# cheat sheet, the Steffon heartbeat steps, deploy-with-task and the devops design
# all still printed the bare form after the rule changed (task
# release-docs-teach-cleared-ship).
#
# This pins the property: every printed `bin/release ship … --yes` in an active doc
# names its `--mode`, unless the same line or the next one says it is `auto` (a doc
# warning against the bare form, or describing a caller that still uses it).
class ReleaseShipNamesItsModeDocsTest < ActiveSupport::TestCase
  DOCS = Rails.root.join("docs/agents")
  SPAN = /`([^`]*\bbin\/release ship\b[^`]*)`/
  FENCED = /^\s*(bin\/release ship\b.*)$/

  def active_docs
    Dir[DOCS.join("**/*.md")].reject { |path| path.include?("/archive/") || path.include?("/maintenance/") }
  end

  def bare_yes?(cmd) = cmd.include?("--yes") && !cmd.include?("--mode")

  # The WORD auto (bare or backticked), never a substring: "autonomous",
  # "automatically" and "autopilot" said nothing about the mode, yet exempted the
  # line (task release-gem-doc-followups).
  def says_auto?(line) = line.to_s.match?(/(?<![\w-])auto(?![\w-])/)

  def offenders
    active_docs.flat_map do |path|
      lines = File.readlines(path)
      lines.each_with_index.flat_map do |line, i|
        cmds = line.scan(SPAN).flatten + line.scan(FENCED).flatten
        said_auto = says_auto?(line) || says_auto?(lines[i + 1])
        cmds.select { |cmd| bare_yes?(cmd) && !said_auto }.map { |cmd| "#{path.delete_prefix("#{Rails.root}/")}:#{i + 1}: #{cmd}" }
      end
    end
  end

  test "the scan sees a bare ship --yes" do
    assert bare_yes?("bin/release ship --yes")
    assert bare_yes?("bin/release ship --by conductor --yes")
    refute bare_yes?("bin/release ship --mode cleared --clearance \"x\" --yes")
    refute bare_yes?("bin/release ship --mode timed --yes")
  end

  test "only the word auto exempts a line, never a word that contains it" do
    assert says_auto?("It names no `--mode`, so it resolves to `auto`.")
    assert says_auto?("a bare --yes is auto")
    refute says_auto?("the explicit autonomous path is `bin/release ship --by conductor --yes`")
    refute says_auto?("read automatically by the autopilot")
    refute says_auto?("--mode auto-ish is not a mode") # a hyphenated compound is not the word
  end

  test "no active doc teaches a bare bin/release ship --yes" do
    assert_empty offenders, "name --mode cleared --clearance or --mode timed (a bare --yes is auto)"
  end

  test "the heartbeat steps name both authority modes" do
    text = DOCS.join("modules/heartbeats.md").read

    assert text.include?("bin/release ship --mode cleared --clearance"), "heartbeats.md names no cleared ship"
    assert text.include?("bin/release ship --mode timed --yes"), "heartbeats.md names no timed ship"
  end
end

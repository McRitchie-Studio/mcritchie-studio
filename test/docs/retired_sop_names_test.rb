# frozen_string_literal: true

require "test_helper"
require_relative "../../bin/lib/sop_registry"

# Retired gate and SOP names resolve only in docs/agents/archive/, and the old
# bin/ship spelling appears in a live doc only on a line that calls it an alias. A
# retired name left in a live doc is an instruction an agent will follow: it resolves
# the name, finds no registry row, and improvises.
class RetiredSopNamesTest < ActiveSupport::TestCase
  DOCS_ROOT = Rails.root.join("docs/agents")

  # RETIRED NAMES RESOLVE ONLY IN THE ARCHIVE. A retired name left in a live doc is
  # an instruction an agent will follow: it resolves the name, finds no row, and
  # improvises. Each pattern names what retired it; the archive keeps the history.
  ARCHIVE = DOCS_ROOT.join("archive")
  RETIRED_NAMES = {
    "the g1_cert gate (the local cert; the PR's settled CI replaced it)" => /\bg1[-_]cert\b|\bG1 Cert\b/i,
    "the qa-deploy SOP alias (qa-release; the qa-deploy.yml workflow is live)" => /\bqa-deploy\b(?!\.yml)/,
    "the archive-completed SOP alias (archive-shipped)" => /\barchive-completed\b/,
    "the Alex Heartbeat alias (Xan Heartbeat)" => /\bAlex Heartbeat\b/
  }.freeze

  # bin/ship and bin/ship-wait are aliases of bin/submit and bin/submit-wait for one
  # release. A live doc may name them only on a line that says so.
  OLD_COMMAND = %r{\bbin/ship(?:-wait)?(?![-\w.])}
  ALIAS_NOTE = /\balias/i

  def live_doc_lines
    Dir.glob(DOCS_ROOT.join("**/*.md")).sort.reject { |p| p.start_with?("#{ARCHIVE}/") }.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      File.readlines(path, chomp: true).each_with_index.map { |line, i| ["#{rel}:#{i + 1}", line] }
    end
  end

  def retired_hits(lines)
    lines.flat_map do |where, line|
      RETIRED_NAMES.filter_map { |name, pattern| "#{where}: #{name}" if line.match?(pattern) }
    end
  end

  test "[unit] retired gate and SOP names resolve nowhere but docs/agents/archive" do
    lines = live_doc_lines
    assert_operator lines.size, :>=, 10_000, "the live-doc scan read too few lines to be the real docs tree"

    assert_empty retired_hits(lines),
                 "a live doc names a retired gate or SOP. Name the live one, or move the history to " \
                 "docs/agents/archive/"
    refute SopRegistry.entries(Rails.root.to_s).any? { |e| e.invocation.match?(Regexp.union(RETIRED_NAMES.values)) },
           "the SOP registry still carries a retired name"
  end

  test "[unit] the retired-name scan bites every retired name and spares the live ones" do
    probes = ["the `g1_cert` gate", "see gates/g1-cert.md", "the G1 Cert chip", "run `qa-deploy`",
              "`archive-completed` sweeps", "launch `Alex Heartbeat`"]
    probes.each do |probe|
      refute_empty retired_hits([["probe", probe]]), "the scan missed #{probe.inspect}"
    end

    ["dispatch `qa-deploy.yml`", "run `qa-release`", "`archive-shipped`", "`Xan Heartbeat`"].each do |live|
      assert_empty retired_hits([["probe", live]]), "the scan refused a live name: #{live.inspect}"
    end
  end

  test "[unit] live docs name bin/submit; bin/ship appears only where a line calls it an alias" do
    stale = live_doc_lines.select { |_, line| line.match?(OLD_COMMAND) && !line.match?(ALIAS_NOTE) }

    assert_empty stale.map(&:first),
                 "these live doc lines name bin/ship or bin/ship-wait; the commands are bin/submit and " \
                 "bin/submit-wait (the old names are one-release aliases)"
    assert_match OLD_COMMAND, "run /Users/alex/projects/.agents/bin/ship-wait x", "the pattern must bite"
    refute_match OLD_COMMAND, "run bin/submit-wait x"
  end
end

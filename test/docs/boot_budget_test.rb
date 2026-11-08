# frozen_string_literal: true

require "test_helper"
require "open3"
require_relative "../../bin/lib/sop_registry"

# THE BOOT BUDGET. Every session loads the boot docs before it does anything:
# docs/agents/claude.md (installed as CLAUDE.md, which Claude Code auto-loads) and
# docs/agents/index.md (installed as AGENTS.md, which CLAUDE.md @imports and Codex reads
# natively). Every byte costs every session. Alex McRitchie's ruling of 2026-11-06 set the
# budget at about 40 KB, and moved the SOP registry table out to start-here.md once a
# resolver (bin/sop) shipped. bin/install-agent-docs copies both files verbatim, so the
# sources measure the installed size.
class BootBudgetTest < ActiveSupport::TestCase
  BUDGET_BYTES = 40_000
  BOOT_DOCS = %w[docs/agents/claude.md docs/agents/index.md].freeze

  def boot_bytes(root)
    BOOT_DOCS.sum { |rel| File.size(File.join(root, rel)) }
  end

  test "[unit] the boot docs stay within the 40 KB budget" do
    size = boot_bytes(Rails.root.to_s)

    assert_operator size, :<=, BUDGET_BYTES,
                    "the boot docs (CLAUDE.md + AGENTS.md as installed) are #{size} bytes, over the " \
                    "#{BUDGET_BYTES}-byte budget. Move detail to a page the map links to; do not raise the budget " \
                    "without Alex McRitchie's ruling."
  end

  # Not inert: the same measure reads a tree that is over budget as over budget.
  test "[unit] the budget measure goes red on an oversized boot doc" do
    Dir.mktmpdir("boot-budget") do |root|
      BOOT_DOCS.each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
        FileUtils.cp(Rails.root.join(rel), File.join(root, rel))
      end
      File.write(File.join(root, "docs/agents/index.md"), "x" * BUDGET_BYTES, mode: "a")

      assert_operator boot_bytes(root), :>, BUDGET_BYTES
    end
  end

  test "[unit] the boot docs carry no SOP registry table" do
    BOOT_DOCS.each do |rel|
      refute_includes Rails.root.join(rel).read, SopRegistry.begin_marker,
                      "#{rel} carries the generated SOP registry again; it lives in start-here.md and bin/sop"
    end
  end

  # The resolver is how an agent turns a name into a file now. Both boot docs say so.
  test "[unit] both boot docs tell an agent to resolve an SOP name with bin/sop" do
    BOOT_DOCS.each do |rel|
      assert_includes Rails.root.join(rel).read, "/Users/alex/projects/.agents/bin/sop <name>",
                      "#{rel} no longer names how to resolve an SOP name"
    end
  end

  # [integration] The script itself: every registered name resolves end to end, and an
  # unknown name fails with suggestions. One process lists every name with its path, so
  # the whole registry is checked without a process per name.
  test "[integration] bin/sop resolves every registered name and refuses an unknown one" do
    sop = Rails.root.join("bin/sop").to_s
    entries = SopRegistry.entries(Rails.root.to_s)

    # stdout only: a Bundler-wrapped run prints platform warnings on stderr.
    listed, err, status = Open3.capture3(sop, "--list")
    assert status.success?, err
    rows = listed.lines.to_h { |line| line.chomp.split("\t").then { |name, _owner, path| [name, path] } }
    assert_equal entries.map(&:invocation), rows.keys
    rows.each { |name, path| assert File.file?(path), "`#{name}` lists #{path}, which is not a file" }

    %w[clean-up pr-review qa-release production-deploy focus-session].each do |name|
      out, err, ok = Open3.capture3(sop, name)
      assert ok.success?, err
      assert_equal rows.fetch(name), out.strip
    end

    out, err, ok = Open3.capture3(sop, "Mason Heartbeat", "--cat")
    assert ok.success?, err
    assert_equal Rails.root.join("docs/agents/agents/mason/HEARTBEAT.md").read, out

    out, err, ok = Open3.capture3(sop, "clean-upp")
    refute ok.success?, "an unknown name must exit non-zero"
    assert_empty out
    assert_includes err, "`clean-up`", "an unknown name must suggest the close names"
  end
end

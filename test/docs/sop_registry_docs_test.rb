# frozen_string_literal: true

require "test_helper"

# The SOP registry is a DECLARATION, and until this test existed nothing checked
# it against the disk. An SOP is invoked by NAME — Mr. McRitchie says `clean-up`
# and the agent is expected to resolve that phrase through the registry table in
# docs/agents/index.md to a file. Three separate surfaces have to agree:
#
#   1. docs/agents/index.md      — TWO registry tables (top-level + reference),
#                                  generated verbatim into $PROJECTS_ROOT/AGENTS.md
#   2. docs/agents/claude.md     — the Claude adapter's prose list of invocations,
#                                  generated into $PROJECTS_ROOT/CLAUDE.md
#   3. docs/agents/agents/<soul>/sops/<sop>.md — the file that actually runs
#
# Add an SOP and forget one table and the failure is SILENT: the agent reads a
# registry that does not name the SOP, treats the invocation as ordinary prose,
# and improvises — which is precisely the drift the SOP Invocation Standard exists
# to kill. The registry claiming an SOP that is not on disk fails the other way:
# the agent is sent to read a file that is not there.
#
# So we assert the POSITIVE INVARIANT — registry and disk are the SAME SET, and
# every registered path resolves — rather than blacklisting the ways they drift.
class SopRegistryDocsTest < ActiveSupport::TestCase
  DOCS_ROOT   = Rails.root.join("docs/agents")
  INDEX       = DOCS_ROOT.join("index.md")
  CLAUDE      = DOCS_ROOT.join("claude.md")
  SOPS_GLOB   = DOCS_ROOT.join("agents/*/sops/*.md")

  # Rows look like:  | `clean-up` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/clean-up.md` |
  # The invocation may carry a trailing note — `pr-review-primary` (role SOP),
  # `qa-deploy` (legacy alias) — so capture the backticked name, not the whole cell.
  ROW = /^\|\s*`([a-z0-9-]+)`[^|]*\|\s*([^|]+?)\s*\|\s*`mcritchie-studio\/(\S+?)`\s*\|/

  def registry_rows
    INDEX.read.lines.filter_map do |line|
      m = ROW.match(line)
      next unless m

      { invocation: m[1], owner: m[2].strip, path: m[3] }
    end
  end

  def sop_files_on_disk
    Dir.glob(SOPS_GLOB).map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }.sort
  end

  test "every registered SOP path exists on disk" do
    missing = registry_rows.reject { |row| Rails.root.join(row[:path]).exist? }

    assert_empty missing.map { |r| "#{r[:invocation]} -> #{r[:path]}" },
                 "The SOP registry in docs/agents/index.md names files that do not exist. An agent told to " \
                 "run one of these would be sent to read a missing file."
  end

  test "every SOP file on disk is registered by name in docs/agents/index.md" do
    registered = registry_rows.map { |r| r[:path] }.to_set
    unregistered = sop_files_on_disk.reject { |path| registered.include?(path) }

    assert_empty unregistered,
                 "These SOP files exist but no registry row in docs/agents/index.md names them. An agent " \
                 "cannot resolve an SOP it cannot find in the registry — it will treat the invocation as " \
                 "ordinary prose and improvise. Add a row to BOTH registry tables."
  end

  # The two tables are the SAME registry printed twice (the second exists for agents
  # that jump straight to the reference section). A name in one and not the other is
  # a coin-flip on which an agent reads.
  test "the two registry tables in index.md name the same set of SOP files" do
    text = INDEX.read
    reference_heading = text.index("## SOP Registry")

    refute_nil reference_heading, "docs/agents/index.md lost its '## SOP Registry' reference section"

    top_paths = text[0...reference_heading].lines.filter_map { |l| ROW.match(l)&.[](3) }
    ref_paths = text[reference_heading..].lines.filter_map { |l| ROW.match(l)&.[](3) }

    # Heartbeat launchers live only in the top table; compare on SOP files, which
    # both tables carry.
    sops = ->(paths) { paths.select { |p| p.include?("/sops/") }.to_set }

    assert_equal sops.call(top_paths), sops.call(ref_paths),
                 "The two SOP registry tables in docs/agents/index.md disagree. Both must list every SOP — " \
                 "an agent may read either one."
  end

  # The Claude adapter names invocations in prose ("such as `pr-review`, …"). It is
  # the file Claude Code AUTO-LOADS, so an SOP it never names is one Claude is least
  # likely to resolve. Assert the adapter's prose list is a subset of the registry —
  # it may abbreviate, but it may never invent.
  test "every invocation the Claude adapter names is a real registered invocation" do
    invocations = registry_rows.map { |r| r[:invocation] }.to_set
    prose = CLAUDE.read[/resolve that phrase/i.match(CLAUDE.read) ? 0..CLAUDE.read.index("resolve that phrase") : 0..0]
    named = prose.to_s.scan(/`([a-z0-9-]+)`/).flatten.select { |n| n.include?("-") }

    unknown = named.reject { |n| invocations.include?(n) }

    assert_empty unknown,
                 "docs/agents/claude.md names SOP invocations that are not in the registry: #{unknown.inspect}. " \
                 "Claude auto-loads this file — it must not point at an SOP that cannot be resolved."
  end

  # The reason this test exists at all.
  test "clean-up resolves end to end" do
    row = registry_rows.find { |r| r[:invocation] == "clean-up" }

    refute_nil row, "`clean-up` is not in the SOP registry"
    assert_equal "Alex", row[:owner]
    assert_path_exists Rails.root.join(row[:path])

    body = Rails.root.join(row[:path]).read
    assert_match(/zero open tasks/i, body, "the clean-up SOP must state its goal: zero open tasks")
    assert_match(/Phase 0 — Scope guard/, body, "the clean-up SOP must carry the carve-out phase")
  end
end

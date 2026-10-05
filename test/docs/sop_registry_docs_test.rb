# frozen_string_literal: true

require "test_helper"

# The SOP registry is a DECLARATION, and until this test existed nothing checked
# it against the disk. An SOP is invoked by NAME — Mr. McRitchie says `clean-up`
# and the agent is expected to resolve that phrase through the registry table in
# docs/agents/index.md to a file. Three separate surfaces have to agree:
#
#   1. docs/agents/index.md      — ONE registry table under `## SOP Registry`,
#                                  generated verbatim into $PROJECTS_ROOT/AGENTS.md
#   2. docs/agents/claude.md     — the Claude adapter's prose list of invocations,
#                                  generated into $PROJECTS_ROOT/CLAUDE.md
#   3. docs/agents/agents/<soul>/sops/<sop>.md — the file that actually runs
#
# Add an SOP and forget the table and the failure is SILENT: the agent reads a
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
  HEARTBEATS_GLOB = DOCS_ROOT.join("agents/*/HEARTBEAT.md")

  # The one heading the registry lives under. The SOP Invocation Standard sends an
  # agent here by name, so the heading is part of the contract, not decoration.
  REGISTRY_HEADING = "## SOP Registry"

  # Rows look like:  | `clean-up` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/clean-up.md` |
  # The invocation may carry a trailing note — `pr-review-primary` (role SOP),
  # `qa-deploy` (legacy alias) — so capture the backticked name, not the whole cell.
  #
  # The name charset MUST admit spaces and capitals. The HEARTBEAT rows are spelled
  # `Avi Heartbeat` / `Steffon Heartbeat` / `Alex Heartbeat`, so a `[a-z0-9-]+` class
  # silently declines to match them — which left every HEARTBEAT.md path completely
  # UNPINNED, in the one class of doc a soul launches from. A regex that quietly
  # matches nothing is the same failure as a gate that quietly passes everything.
  ROW = /^\|\s*`([A-Za-z0-9][A-Za-z0-9 -]*)`[^|]*\|\s*([^|]+?)\s*\|\s*`mcritchie-studio\/(\S+?)`\s*\|/

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

  def heartbeat_files_on_disk
    Dir.glob(HEARTBEATS_GLOB).map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }.sort
  end

  # The text under REGISTRY_HEADING, up to the next H2. The rows an agent resolves
  # a name through are the rows in THIS section; a row anywhere else in the map is
  # a second copy waiting to drift.
  def registry_section
    text = INDEX.read
    start = text.index("#{REGISTRY_HEADING}\n")
    refute_nil start, "docs/agents/index.md lost its '#{REGISTRY_HEADING}' section"

    rest = text[(start + REGISTRY_HEADING.length)..]
    stop = rest.index(/^## /)
    stop ? rest[0...stop] : rest
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
                 "ordinary prose and improvise. Add a row under '#{REGISTRY_HEADING}'."
  end

  # The heartbeat is the one doc a soul LAUNCHES from, and the SOP glob above does
  # not see it (it lives beside sops/, not inside it). Pin the disk→registry
  # direction for heartbeats on its own, so a new soul's HEARTBEAT.md cannot land
  # without the row an agent resolves `<Soul> Heartbeat` through.
  test "every heartbeat file on disk is registered by name in docs/agents/index.md" do
    files = heartbeat_files_on_disk

    assert_operator files.length, :>=, 3,
                    "the HEARTBEAT.md glob found only #{files.length} file(s); the souls carry at least " \
                    "Carl, Avi and Steffon, so the glob has stopped seeing them"

    registered = registry_rows.map { |r| r[:path] }.to_set
    unregistered = files.reject { |path| registered.include?(path) }

    assert_empty unregistered,
                 "These heartbeat files exist but no registry row in docs/agents/index.md names them. " \
                 "Add a `<Soul> Heartbeat` row under '#{REGISTRY_HEADING}'."
  end

  # The registry is one table under one heading. A second copy anywhere in the map
  # is a coin flip on which one an agent reads, and the two drift the first time an
  # SOP is added to one and not the other. So: one heading, every row inside it,
  # and no name on two rows.
  test "index.md carries the SOP registry exactly once" do
    text = INDEX.read
    headings = text.scan(/^#{Regexp.escape(REGISTRY_HEADING)}\s*$/)

    assert_equal 1, headings.length,
                 "docs/agents/index.md carries '#{REGISTRY_HEADING}' #{headings.length} time(s); the " \
                 "SOP Invocation Standard sends an agent to exactly one"

    rows_in_section = registry_section.lines.count { |l| ROW.match?(l) }
    rows_in_file = text.lines.count { |l| ROW.match?(l) }

    # The floor first: a section that parses to nothing would make the equality
    # below a statement about two empty sets.
    assert_operator rows_in_section, :>=, 40,
                    "only #{rows_in_section} registry rows parsed under '#{REGISTRY_HEADING}'; the ROW " \
                    "regex or the section cut has gone blind"
    assert_equal rows_in_file, rows_in_section,
                 "#{rows_in_file - rows_in_section} registry-shaped row(s) sit outside the " \
                 "'#{REGISTRY_HEADING}' section of docs/agents/index.md; the registry lives in that " \
                 "one table, so move them there"

    repeated = registry_rows.map { |r| r[:invocation] }.tally.select { |_, n| n > 1 }.keys

    assert_empty repeated,
                 "these invocations have more than one row in docs/agents/index.md: #{repeated.inspect}. " \
                 "One name resolves through one row; a second row is a copy that will drift"
  end

  # The one class of doc a soul LAUNCHES from. Pinned explicitly, because they are the
  # rows the old `[a-z0-9-]+` name class silently declined to match (`Avi Heartbeat` —
  # space, capitals), leaving every HEARTBEAT.md path completely unverified.
  test "every heartbeat launcher in the registry exists on disk" do
    heartbeats = registry_rows.select { |r| r[:path].end_with?("HEARTBEAT.md") }

    assert_operator heartbeats.length, :>=, 3,
                    "expected the Avi/Steffon/Alex heartbeat rows in the registry; the ROW regex may have " \
                    "stopped matching them again (they carry a SPACE and CAPITALS)"

    heartbeats.each do |row|
      assert_path_exists Rails.root.join(row[:path]),
                         "registry names heartbeat #{row[:invocation]} -> #{row[:path]}, which does not exist"
    end
  end

  # The Claude adapter names invocations in prose ("such as `pr-review`, …"). It is
  # the file Claude Code AUTO-LOADS, so an SOP it never names is one Claude is least
  # likely to resolve. Assert the adapter's prose list is a subset of the registry —
  # it may abbreviate, but it may never invent.
  test "every invocation the Claude adapter names is a real registered invocation" do
    invocations = registry_rows.map { |r| r[:invocation] }.to_set
    body = CLAUDE.read

    # The scan is SCOPED to the SOP-invocation sentence on purpose. A whole-file scan
    # for backticked hyphenated tokens over-reaches: the adapter legitimately names the
    # feature SHAPES (`ui-only`, `onchain-vertical`) and other hyphenated terms that are
    # not SOPs, so it would fail on correct docs — a guard that cries wolf gets deleted.
    #
    # But the FIRST cut of this test scoped it and stopped there, which fails OPEN: a
    # bogus SOP name injected AFTER the anchor kept the test GREEN, and any reword that
    # moved the list — or renamed the anchor — turned the whole assertion into a silent
    # NO-OP with nothing to tell you. So the anchor itself is now ASSERTED, and so is a
    # non-empty result. A check that can be switched off by editing prose is not a check.
    anchor = body.index("resolve that phrase")
    refute_nil anchor,
               "docs/agents/claude.md no longer contains the 'resolve that phrase' SOP-invocation anchor. " \
               "This test scopes its scan to that sentence — without the anchor it would silently check " \
               "NOTHING. Restore the anchor, or rewrite this test to scan whatever replaced it."

    named = body[0..anchor].scan(/`([a-z0-9][a-z0-9-]*-[a-z0-9-]*)`/).flatten.uniq

    # A subset assertion over an EMPTY set passes trivially — the exact way this family
    # of test fails open. Prove the scan is looking at something before trusting it.
    assert_operator named.length, :>=, 3,
                    "the Claude adapter's SOP sentence names no invocations at all — either it was " \
                    "reworded past recognition, or this scan has quietly stopped seeing them"

    unknown = named.reject { |n| invocations.include?(n) }

    assert_empty unknown,
                 "docs/agents/claude.md names SOP invocations that are not in the registry: #{unknown.inspect}. " \
                 "Claude auto-loads this file — it must not point at an SOP that cannot be resolved."
  end

  # The reason this test exists at all.
  test "clean-up resolves end to end" do
    row = registry_rows.find { |r| r[:invocation] == "clean-up" }

    refute_nil row, "`clean-up` is not in the SOP registry"
    assert_equal "Xan", row[:owner]
    assert_path_exists Rails.root.join(row[:path])
  end

  # OWNERSHIP IS STRUCTURE, NOT PROSE. A registry row names an owner and a path, and
  # the path already says whose SOP it is: agents/<soul>/sops/… for a soul, modules/…
  # for a shared primitive. Retargeted from doc_owner_prose_guard_test.rb (deleted in
  # trim-docs-guard-tests), which chased wrong-owner SPELLINGS across the docs.
  test "every registry row's owner is the soul whose directory holds the file" do
    rows = registry_rows
    assert_operator rows.size, :>=, 40, "the registry scan matched too few rows to be the real table"

    wrong = rows.filter_map do |row|
      expected = row[:path][%r{\Adocs/agents/agents/([^/]+)/}, 1]&.then { |dir| dir.split("_").map(&:capitalize).join(" ") }
      expected ||= "Shared" if row[:path].start_with?("docs/agents/modules/")
      "#{row[:invocation]}: owner #{row[:owner].inspect}, path #{row[:path]}" unless row[:owner] == expected
    end

    assert_empty wrong, "a registry row names an owner other than the soul whose directory holds its file"
  end

  # /stages/sop renders config/devops_vocabulary.yml. Its Assemble and Ship lanes must
  # be owned by the soul the registry names for the SOP each lane runs, so the board
  # and the registry cannot disagree about who runs a release.
  test "the vocabulary's release lanes are owned by the registry's owner of their SOP" do
    owners = Devops::Vocabulary.lanes.to_h { |lane| [lane[:lane], lane[:owner]] }
    registry = registry_rows.to_h { |r| [r[:invocation], r[:owner]] }

    { "Assemble" => "qa-release", "Ship" => "production-deploy" }.each do |lane, sop|
      refute_nil registry[sop], "`#{sop}` is not in the SOP registry"
      assert_equal registry[sop], owners[lane],
                   "the #{lane} lane in config/devops_vocabulary.yml is owned by #{owners[lane].inspect}, " \
                   "but the registry gives `#{sop}` to #{registry[sop]}"
    end
  end
end

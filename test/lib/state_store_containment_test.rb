# frozen_string_literal: true

# THE ARCHITECTURE TEST for the operator's real state stores — the one that
# catches THE CALLER THAT DOES NOT EXIST YET.
#
#   ruby -Itest test/lib/state_store_containment_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# WHY A STATIC TEST AND NOT MORE RUNTIME TESTS. The bin/ stack writes five stores
# OUTSIDE its repo, under the operator's real <projects>/.agents (see
# lib/task_usage_sandbox.rb). Two of them have already leaked into that live store
# from the test suite: the cost baselines (PR #525) and the narration markers
# (PR #549). Both fixes added a guarded API and behavioural tests that drove it —
# and BOTH still shipped an unguarded caller, because a test of the guarded surface
# cannot see a caller that never enters it. #549's reviewer found
# `clear_activity_usage_baselines` raw-`File.delete`ing the operator's live
# .activity-usage.json on the COMMON close path, sitting right beside a guarded
# sibling that did the same job correctly. Four violation shapes had been driven
# through the guarded API; none of them could ever have caught it.
#
# So the containment is asserted against the TREE, not against the callers someone
# remembered. A guard that only guards the callers you thought of is a naming
# convention with a test suite.
#
# THE INVARIANT, stated positively — this is what is enforced:
#
#   LAYER 1 (who may NAME the store).  Only the files in ALLOWED_CONSTRUCTORS may
#     construct a path under <projects>/.agents at all. Asserted as an EQUALITY, so
#     it fails in BOTH directions: a new file that names the store fails (default
#     DENY — whatever it meant to do with it, including an IO spelling nobody here
#     imagined, because this layer never looks at IO), and a store that moves or is
#     renamed also fails instead of leaving a vacuously-green test behind.
#
#   LAYER 2 (what those files may DO with it).  Inside an allowed constructor, any
#     method that both (a) reaches a RAW store path and (b) performs filesystem IO
#     must launder that path through TaskUsageSandbox.enforce! in the same method.
#     Methods that only READ a store path are fine unguarded — a read cannot
#     pollute — which is why bin/agent-marker and bin/atomic-capture-hook are on the
#     list at all.
#
# Note what the invariant does NOT say: it does not say "goes through SessionMarkers".
# bin/task legitimately hand-rolls its own marker path and calls enforce! itself.
# The choke point is the GUARD, not any one module.
#
# This test reads source text. It never spawns, never writes, and never touches the
# real store.

require "minitest/autorun"
require "set"

class StateStoreContainmentTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Every file permitted to construct a path under the operator's real .agents, and
  # WHY it is permitted. The value is the justification a reviewer reads when a diff
  # adds a line here — adding an entry must be a deliberate, defensible act, not a
  # way to make a red test green.
  ALLOWED_CONSTRUCTORS = {
    "lib/task_usage_sandbox.rb" => "the guard itself — it must name .agents to defend it",
    "bin/lib/session_markers.rb" => "narration-marker choke point: marker_path is PRIVATE; write/delete enforce",
    "bin/lib/agent_api.rb" => "agent-token cache: every mutation goes through guarded_token_cache_path",
    "bin/task" => "active-feature marker + cost store: enforce! at each write seam",
    "bin/release.rb" => "conductor locks + cost store: enforce! at each seam",
    "bin/reviewer-select" => "cost store: enforce! at its dir seam",
    "bin/agent-worktree" => "registry + worktree lock + redis band: enforce! at each seam",
    "bin/agent-marker" => "READ-ONLY resolver — prints/reads the marker, mutates nothing",
    "bin/atomic-capture-hook" => "READ-ONLY — finds the open-activity marker, mutates nothing",
    "bin/qa-intake" => "READ-ONLY — reads the worktree registry; the WRITER is bin/agent-worktree"
  }.freeze

  # A path INTO the operator's real state dir is constructed by naming ".agents" in a
  # File.join, or by reaching the marker store's (private) builder. Prose in a comment
  # — "<projects>/.agents/locks" — cannot match: these require real code syntax.
  SOURCE_RE = /File\.join\([^)]*"\.agents"|SessionMarkers\.marker_path\(|send\(:marker_path/

  # Filesystem MUTATION. Deliberately over-broad (File.open in any mode, mkdir_p):
  # a false positive here is absolved by laundering the path, while a missed sink is
  # a leak. Fail closed, in the test as in the code.
  SINK_RE = /\b(?:File\.(?:write|delete|unlink|rename|truncate|open)|IO\.write|
               FileUtils\.(?:rm|rm_f|rm_rf|remove|remove_entry|mv|cp|touch|mkdir_p|makedirs))\b/x

  LAUNDER_RE = /TaskUsageSandbox\.enforce!/

  # ── the scanner ────────────────────────────────────────────────────────────────
  # Pure text in, findings out — so the "does this checker actually catch anything?"
  # test below can drive it with a synthetic violating file instead of me having to
  # vandalise a real bin/ script to prove it works.

  Method = Struct.new(:name, :body, :line, keyword_init: true)

  # Split Ruby source into method bodies, keyed by the `end` that matches each `def`
  # at the same indentation (plus endless `def x = expr`, which has no `end` — miss
  # that and the splitter swallows the NEXT method's body whole). Its accuracy is
  # itself asserted below; a blind splitter is a silently-green scan.
  def methods_in(src)
    lines = src.lines
    lines.each_with_index.filter_map do |line, i|
      next unless (m = line.match(/^(\s*)def\s+(?:self\.)?([A-Za-z_][\w?!]*)/))

      indent = m[1]
      endless = line.match?(/^\s*def\s+(?:self\.)?[A-Za-z_][\w?!]*(?:\([^)]*\))?\s*=/)
      close = endless ? i : (i + 1...lines.length).find { |j| lines[j] =~ /^#{indent}end\b/ }
      Method.new(name: m[2], line: i + 1, body: lines[i..(close || lines.length - 1)].join)
    end
  end

  # BLANK comment lines rather than delete them, so every reported line number still
  # points at the real file. (Prose is excluded from the scan; a header that says
  # "<projects>/.agents/locks" is not a path construction.)
  def strip_comments(src)
    src.lines.map { |l| l.strip.start_with?("#") ? "\n" : l }.join
  end

  # The last expression a method evaluates — its RETURN value, near enough for these
  # scripts. `rescue`/`ensure`/`end`/bare-`nil` tails are the best-effort epilogue
  # every one of these callers shares, never the value that matters.
  def return_line(body)
    body.lines[1..].to_a.map(&:strip)
        .reject { |l| l.empty? || l.start_with?("#") }
        .reject { |l| l =~ /\A(end|rescue\b.*|ensure|nil)\z/ }
        .last.to_s
  end

  # Methods that RESOLVE a raw (unlaundered) store path — the footguns.
  #
  # A producer RETURNS a path. That distinction is the whole correctness of this
  # scan: `read_cached_token` CALLS the path builder but returns the token STRING, and
  # an earlier draft that treated "calls a producer" as "is a producer" propagated
  # taint through it into a method named `token` — after which the word "token"
  # appearing in ANY body (`"token" => tok`) read as a store path. It reported the
  # already-fixed write_cached_token and would have gone on reporting phantoms until
  # someone loosened the check to shut it up. So: return-position only, fixpoint over
  # indirection (snapshot_path → agent_registry_dir), and a laundering method is not a
  # producer at all — it hands back a GUARDED path, which is the point of it.
  def raw_producers(methods)
    producers = Set.new
    loop do
      before = producers.size
      methods.each do |m|
        next if producers.include?(m.name)
        next if m.body =~ LAUNDER_RE

        ret = return_line(m.body)
        via = producers.any? { |p| p != m.name && ret =~ /\b#{Regexp.escape(p)}\b/ }
        producers << m.name if ret =~ SOURCE_RE || via
      end
      break if producers.size == before
    end
    producers
  end

  # A violation: a method that touches a raw store path AND performs filesystem IO,
  # without laundering it through the guard first.
  def violations_in(src, path: "(memory)")
    code = strip_comments(src)
    methods = methods_in(code)
    raw = raw_producers(methods)

    methods.filter_map do |m|
      next if m.body =~ LAUNDER_RE
      next unless m.body =~ SINK_RE

      reaches = (m.body =~ SOURCE_RE) ||
                raw.any? { |p| p != m.name && m.body =~ /\b#{Regexp.escape(p)}\b/ }
      next unless reaches

      "#{path}:#{m.line} #{m.name} — performs filesystem IO on a raw <projects>/.agents path " \
        "without TaskUsageSandbox.enforce!"
    end
  end

  def ruby_sources
    files = Dir.glob(File.join(ROOT, "bin", "**", "*")) + Dir.glob(File.join(ROOT, "lib", "**", "*.rb"))
    files.select { |f| File.file?(f) && ruby?(f) }
         .map { |f| [f.delete_prefix("#{ROOT}/"), File.read(f)] }
  end

  def ruby?(path)
    return true if path.end_with?(".rb")
    return false if File.extname(path) != ""

    File.open(path) { |f| f.gets }.to_s.include?("ruby")
  rescue StandardError
    false
  end

  # ── LAYER 1 — only these files may NAME the store ──────────────────────────────

  def test_unit_only_allowed_files_construct_a_path_under_the_real_agents_dir
    found = ruby_sources.filter_map { |path, src| path if strip_comments(src) =~ SOURCE_RE }.to_set

    unexpected = found - ALLOWED_CONSTRUCTORS.keys.to_set
    assert_empty unexpected.to_a,
                 "These files construct a path under the operator's real <projects>/.agents but are not " \
                 "sanctioned to.\nEvery such path must come from a guarded seam (TaskUsageSandbox.enforce!) " \
                 "or a guarded API (SessionMarkers.write/delete).\nIf this file genuinely must resolve the " \
                 "store, add it to ALLOWED_CONSTRUCTORS with the reason — and make sure LAYER 2 passes."

    # The other direction. Without this, renaming the store (or deleting the last
    # real constructor) leaves a test that passes because it now checks NOTHING.
    stale = ALLOWED_CONSTRUCTORS.keys.to_set - found
    assert_empty stale.to_a,
                 "ALLOWED_CONSTRUCTORS lists files that no longer construct a store path. Drop them — a " \
                 "stale allowlist is how this test quietly stops testing anything."
  end

  # ── LAYER 2 — and what they may DO with it ─────────────────────────────────────

  def test_unit_no_raw_state_store_path_reaches_filesystem_io_unguarded
    violations = ruby_sources.flat_map { |path, src| violations_in(src, path: path) }

    assert_empty violations,
                 "Raw <projects>/.agents path reaching filesystem IO without the guard:\n  " +
                 violations.join("\n  ") +
                 "\n\nRoute it through TaskUsageSandbox.enforce!(path, store: …) — or, for the narration " \
                 "markers, through SessionMarkers.write/delete, which enforce for you. This is exactly the " \
                 "shape of the bug PR #549's review caught: a raw File.delete beside a guarded sibling."
  end

  # ── the checker itself must be able to FAIL ────────────────────────────────────
  # A green architecture test is worthless if it is green because it finds nothing.
  # Drive the scanner with the ACTUAL bug (bin/atomic-event's raw delete, as it stood
  # before the fix) and with its guarded sibling, and assert it separates them.

  def test_unit_scanner_catches_the_bug_it_was_written_for
    regressed = <<~RUBY
      def activity_usage_path(session_id)
        SessionMarkers.marker_path(session_id, projects_dir, ACTIVITY_USAGE)
      end

      def clear_activity_usage_baselines(session_id)
        path = activity_usage_path(session_id)
        File.delete(path) if File.file?(path)
      rescue StandardError
        nil
      end
    RUBY

    found = violations_in(regressed, path: "bin/atomic-event")
    assert_equal 1, found.size, "the scanner must flag the raw delete (got: #{found.inspect})"
    assert_match(/clear_activity_usage_baselines/, found.first)
  end

  def test_unit_scanner_passes_the_guarded_sibling_and_the_read_path
    guarded = <<~RUBY
      def clear_acting_agent(session_id)
        SessionMarkers.delete(session_id, projects_dir, ACTING_AGENT, env: @api.env)
      end

      def write_feature_marker(task)
        path = feature_marker_path
        path = TaskUsageSandbox.enforce!(path, store: "session-marker")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "x")
      end

      def feature_marker_path
        File.join(PROJECTS_DIR, ".agents", "sessions", "s.json")
      end

      def read_marker(session_id)
        path = feature_marker_path
        File.read(path) if File.file?(path)
      end
    RUBY

    assert_empty violations_in(guarded),
                 "a laundered write, a guarded-API delete, and an unguarded READ are all legitimate"
  end

  # A novel IO spelling the SINK_RE never anticipated still cannot reach the store,
  # because LAYER 1 refuses the file the moment it names .agents. This is the property
  # the whole design leans on, so assert it rather than assume it.
  def test_unit_layer_one_catches_an_io_spelling_the_sink_list_never_imagined
    exotic = <<~RUBY
      def nuke(session_id)
        p = File.join(projects_dir, ".agents", "sessions", "x.json")
        Pathname.new(p).delete
        system("rm -rf \#{p}")
      end
    RUBY

    assert_match SOURCE_RE, strip_comments(exotic),
                 "LAYER 1 keys on NAMING the store, so it is blind to how the file intends to write it — " \
                 "Pathname#delete and a shell rm are refused for the same reason a File.write is"
  end

  def test_unit_scanner_finds_the_known_methods
    src = File.read(File.join(ROOT, "bin", "lib", "session_markers.rb"))
    names = methods_in(src).map(&:name)

    %w[marker_path write_path write delete read].each do |expected|
      assert_includes names, expected, "the method splitter missed #{expected} — the scan would be blind"
    end
  end
end

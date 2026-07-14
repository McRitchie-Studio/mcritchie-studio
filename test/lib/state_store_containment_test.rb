# frozen_string_literal: true

# THE ARCHITECTURE TEST for the operator's real state stores — the one that
# catches THE CALLER THAT DOES NOT EXIST YET.
#
#   bin/rails test test/lib/state_store_containment_test.rb
#
# WHY A STATIC TEST AND NOT MORE RUNTIME TESTS. The bin/ stack writes SEVEN stores
# OUTSIDE its repo, under the operator's real <projects>/.agents (see
# lib/task_usage_sandbox.rb). Two of them have already leaked into that live store
# from the test suite: the cost baselines (PR #525) and the narration markers
# (PR #549). Both fixes added a guarded API and behavioural tests that drove it —
# and BOTH still shipped an unguarded caller, because a test of the guarded surface
# cannot see a caller that never enters it. #549's reviewer found
# `clear_activity_usage_baselines` raw-`File.delete`ing the operator's live
# .activity-usage.json on the COMMON close path, sitting right beside a guarded
# sibling that did the same job correctly. Four violation shapes had been driven
# through the guarded API; none of them could ever have caught it. That is the
# structural reason the PRIMARY lane here is static: an execution test observes the
# callers you drove, never the caller nobody remembered to drive.
#
# ── WHY THIS TEST WAS REWRITTEN (the review that caught it) ────────────────────
#
# Its first draft asserted containment on TWO axes: who NAMES the store, and which
# IO SINK they reach it with (a SINK_RE list of File.write/File.delete/FileUtils.*).
# Both axes were enumerations of spellings, and an enumeration of spellings only
# refuses the spellings someone thought to refuse:
#
#   * it keyed "names the store" on `File.join(..., ".agents", ...)`, so a
#     bin/leaky-demo deleting the operator's live .open-activity with ORDINARY
#     interpolation — File.delete("#{projects_dir}/.agents/sessions/#{id}...") —
#     was invisible, and the suite stayed GREEN;
#   * inside an allowlisted file the sink list was the only guard, and
#     system("rm #{p}"), backticks, Pathname#delete, File.binwrite, File.new(p,"w")
#     and FileUtils.rmtree all walked straight through it. A shell-out cannot be
#     seen by a Ruby sink scan AT ALL — not "was missed", CANNOT be seen.
#
# THE MECHANISM THAT REPLACED THEM — guard the PRECONDITION, not the verb.
#
#   You cannot write to a path you never named.
#
# The path is the NECESSARY precondition of every mutation — every IO verb, every
# shell-out, every subprocess, in every language. So the sink axis is DELETED from
# this scan. Nothing here looks at what a method does with a path; it looks only at
# whether the method HOLDS a raw one. `system("rm #{p}")` is refused not because a
# shell-out was imagined and added to a list, but because the method held the path.
# There is no list of verbs left to be incomplete.
#
# The unit of ALLOWANCE moved with it. The old design allowed by VERB (an unbounded
# set — one you can only ever blacklist, and so can only ever under-refuse). This one
# allows by FILE and by METHOD (bounded, human-scale, reviewable sets, each carrying
# the reason a reviewer reads in the diff). Default-DENY at both levels, asserted as
# an EQUALITY so a stale entry fails too — an allowlist that quietly stops matching
# reality is how an architecture test stops testing anything.
#
# ── THE INVARIANT, stated positively ──────────────────────────────────────────
#
#   LAYER 1 (who may NAME the store).  Only ALLOWED_CONSTRUCTORS may construct a path
#     under <projects>/.agents at all — in ANY spelling: File.join, interpolation, a
#     joined ".agents/sessions" subpath, a constant, Pathname#join, bash. A file that
#     names the store is refused whatever it meant to do with it, because this layer
#     never looks at IO.
#
#   LAYER 2 (what those files may DO with it).  Inside an allowed constructor, EVERY
#     method that reaches a raw store path must launder it through
#     TaskUsageSandbox.enforce! — unless it is named in UNGUARDED_PATH_METHODS, which is a
#     closed, justified list (a read cannot pollute). No IO analysis: holding the raw
#     path is the violation.
#
#   LAYER 2a (the path may not ESCAPE).  A required lemma, not a nicety. Layer 1 only
#     works if a file that has not named .agents cannot GET a raw path some other way.
#     So the two shared libs (bin/lib/*.rb — the only store-namers other files
#     `require_relative`) may export NO public raw-path builder. Both keep theirs
#     private. Without this, a caller could `File.delete(AgentApi.new.token_cache_path)`
#     and never type ".agents" — invisible to Layer 1 by construction.
#
#   Together: a raw path cannot be obtained without naming the store (2a), naming the
#   store is refused outside the allowlist (1), and inside the allowlist a raw path
#   cannot reach anything unlaundered (2). THAT is the closure argument, and it is an
#   argument about paths, not about verbs.
#
# ── WHAT THIS TEST CANNOT SEE — stated, because a guarantee oversold is worse ──
# than none. The prose here is load-bearing; do not let it drift from the code.
#
#   * BASH. bin/statusline writes this store and is bash, so LAYER 2's Ruby method
#     splitter cannot read it — not imperfectly, at all. It is held to LAYER 1 (it may
#     name the store) and its USAGE is proven at the BOUNDARY instead: LAYER 3 below
#     EXECUTES it, armed and unpinned, and observes the real filesystem. A bash write
#     and a shell-out are invisible to any Ruby source scan and cannot hide from that.
#   * DYNAMIC ASSEMBLY. `File.join(dir, ".age" + "nts")` names the store without the
#     literal appearing. No scan of text defeats a program that computes its own
#     strings; LAYER 3's filesystem observation is the answer to that class, and it
#     only sees the commands it drives.
#   * SCOPE. bin/** and lib/**/*.rb — the stack that owns these stores. test/ names
#     the store legitimately (it asserts on it) and is excluded.
#
# This test's LAYER 1/2/2a read source text: they never spawn, never write, never
# touch the real store. LAYER 3 spawns, and does so under a session id minted fresh
# for the assertion, so it can never collide with a live session's markers.

require "minitest/autorun"
require "set"
require "open3"
require "securerandom"
require "tmpdir"
require_relative "../../lib/task_usage_sandbox"

class StateStoreContainmentTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Every file permitted to construct a path under the operator's real .agents, and
  # WHY it is permitted. The value is the justification a reviewer reads when a diff
  # adds a line here — adding an entry must be a deliberate, defensible act, not a
  # way to make a red test green.
  #
  # :ruby     — held to LAYER 2. Every raw path it holds is laundered or listed.
  # :guard    — the guard itself. It must name .agents to DEFINE the forbidden root;
  #             asking it to launder its own definition is circular. Exactly one file
  #             may carry this, and LAYER 2 asserts that.
  # :bash     — LAYER 2 is structurally blind here. Held to LAYER 3 instead.
  ALLOWED_CONSTRUCTORS = {
    "lib/task_usage_sandbox.rb" => [:guard, "the guard itself — it names .agents to DEFINE the forbidden root"],
    "bin/lib/session_markers.rb" => [:ruby, "narration-marker choke point: marker_path is PRIVATE; write/delete enforce"],
    "bin/lib/agent_api.rb" => [:ruby, "agent-token cache: every mutation goes through guarded_token_cache_path"],
    "bin/task" => [:ruby, "active-feature marker + cost store: enforce! at each write seam"],
    "bin/release.rb" => [:ruby, "conductor locks + cost store: enforce! at each seam"],
    "bin/reviewer-select" => [:ruby, "cost store: enforce! at its dir seam"],
    "bin/agent-worktree" => [:ruby, "registry + worktree lock + redis band: enforce! at each seam"],
    "bin/agent-marker" => [:ruby, "READ-ONLY resolver — prints/reads the marker, mutates nothing"],
    "bin/atomic-capture-hook" => [:ruby, "READ-ONLY — finds the open-activity marker, mutates nothing"],
    "bin/qa-intake" => [:ruby, "READ-ONLY — reads the worktree registry; the WRITER is bin/agent-worktree"],
    "bin/statusline" => [:bash, "BASH heartbeat throttles — LAYER 2 cannot read it; LAYER 3 executes it"]
  }.freeze

  # THE ENTIRE EXEMPTION SURFACE of LAYER 2 — every method allowed to hold a raw store
  # path WITHOUT laundering it, and the reason. Each entry is a claim, made in a diff a
  # reviewer reads, that the method DOES NOT MUTATE the store. Two shapes qualify:
  #
  #   BUILDER — it RESOLVES the path and returns it, and does nothing else with it. Its
  #             consumers are scanned like everything else, so exempting the builder
  #             exempts nothing: the mutation still has to launder, wherever it happens.
  #   READ    — it uses the path to read. A read cannot pollute.
  #
  # This list REPLACES the old SINK_RE, and the replacement is the whole point of the
  # rewrite. SINK_RE enumerated the VERBS that were FORBIDDEN — an unbounded set, so it
  # could only ever be a blacklist, and the verb you forget is the leak (it forgot
  # system(), backticks, Pathname#delete, File.binwrite, FileUtils.rmtree…). This
  # enumerates the METHODS that are PERMITTED — a bounded set a reviewer can read in
  # full. Anything not on it is refused, whatever verb it reaches for, in whatever
  # language it shells out to. There is no list left that can be incomplete.
  UNGUARDED_PATH_METHODS = {
    "bin/lib/session_markers.rb" => {
      "marker_path" => "BUILDER — private; the exported mutations (write/delete) launder it",
      "read" => "READ — returns the marker's contents"
    },
    "bin/lib/agent_api.rb" => {
      "token_cache_path" => "BUILDER — private; guarded_token_cache_path is what mutations use",
      "read_cached_token" => "READ — returns the cached token, never writes"
    },
    "bin/task" => {
      "feature_marker_path" => "BUILDER — write_feature_marker launders it at the write seam",
      "usage_audit!" => "READ — TaskUsageAudit.report only reports; it never purges (bin/task:1250)",
      "session_marker_persona" => "READ — reads the marker to pick the session's mascot"
    },
    "bin/release.rb" => {
      "primary_checkout_lock_dir" => "BUILDER — pure resolver; guarded_lock_dir launders before mkdir_p"
    },
    "bin/agent-worktree" => {
      "agent_registry_dir" => "BUILDER — the root the three worktree stores hang off",
      "snapshot_path" => "BUILDER — write_snapshot launders it",
      "redis_capacity_path" => "BUILDER — write_current_capacity launders it",
      "worktree_lock_path" => "BUILDER — with_worktree_lock launders it before the flock",
      "load_current_capacity" => "READ — parses the Redis band; write_current_capacity is the writer"
    },
    "bin/agent-marker" => {
      "session_path" => "BUILDER — for the READ below; this script mutates nothing",
      "resolve_marker" => "READ — resolves and returns the marker for printing"
    },
    "bin/atomic-capture-hook" => {
      "read_open_activity" => "READ — finds the open activity to attribute a captured action"
    },
    # Nothing to exempt: both hold their store path in an INERT top-level form (a
    # constant, a hash value) and launder at every seam that acts on it.
    "bin/reviewer-select" => {},
    "bin/qa-intake" => {}
  }.freeze

  # NAMING the store — in ANY spelling. This is the precondition of every mutation, so
  # this regex is the whole scan's foundation and it is deliberately BLUNT:
  #
  #   File.join(dir, ".agents", …)            the original — and the ONLY one the first
  #                                           draft of this test could see
  #   "#{projects_dir}/.agents/sessions/…"    ORDINARY INTERPOLATION — the spelling that
  #                                           defeated it (a real bin/leaky-demo)
  #   File.join(dir, ".agents/sessions")      a joined subpath
  #   AGENTS = ".agents"                      a constant indirection
  #   Pathname.new(dir).join(".agents")       a different receiver
  #   "$PROJECTS/.agents/sessions/…"          bash
  #
  # All six must NAME the segment, and none of them can avoid it — which is why the
  # match is on the SEGMENT and not on the syntax around it.
  #
  # The lookarounds make it a PATH segment rather than the letters: `block.agents` and
  # `reviewed.agents` (app/helpers/stage_agents_helper.rb) are method calls, not paths,
  # and `.agentsx` is a different name. Comments are stripped before the scan, so prose
  # — "<projects>/.agents/locks" in a header — cannot match.
  #
  # The marker_path clauses are belt-and-braces for LAYER 2a: they catch a reach into
  # the (private) builder even though 2a makes such a reach impossible to obtain.
  PATH_RE = /(?<!\w)\.agents(?!\w)|SessionMarkers\.marker_path\(|send\(:marker_path/

  LAUNDER_RE = /TaskUsageSandbox\.enforce!/

  # ── the scanner ────────────────────────────────────────────────────────────────
  # Pure text in, findings out — so the "does this checker actually catch anything?"
  # tests below can drive it with synthetic violating files instead of me having to
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
  # "<projects>/.agents/locks" is not a path construction. `#` comments both languages.)
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

  # Names that RESOLVE a raw (unlaundered) store path — the footguns a later method can
  # pick up without ever naming .agents itself.
  #
  # A producer RETURNS a path. That distinction is the whole correctness of this scan:
  # `read_cached_token` CALLS the path builder but returns the token STRING, and an
  # earlier draft that treated "calls a producer" as "is a producer" propagated taint
  # through it into a method named `token` — after which the word "token" appearing in
  # ANY body (`"token" => tok`) read as a store path. So: return-position only, fixpoint
  # over indirection (snapshot_path → agent_registry_dir), and a laundering method is not
  # a producer at all — it hands back a GUARDED path, which is the point of it.
  #
  # CONSTANTS are producers too (`SESSIONS = File.join(root, ".agents", "sessions")`),
  # which is the constant-indirection vector: without this, the method that uses the
  # constant names nothing and reads as clean.
  def raw_producers(src, methods)
    producers = src.lines.filter_map do |l|
      next unless l =~ PATH_RE

      m = l.match(/^\s*([A-Z][A-Z0-9_]*)\s*=[^=]/)
      m && m[1]
    end.to_set

    loop do
      before = producers.size
      methods.each do |m|
        next if producers.include?(m.name)
        next if m.body =~ LAUNDER_RE

        ret = return_line(m.body)
        via = producers.any? { |p| p != m.name && ret =~ /\b#{Regexp.escape(p)}\b/ }
        producers << m.name if ret =~ PATH_RE || via
      end
      break if producers.size == before
    end
    producers
  end

  # A violation: a method that REACHES a raw store path without laundering it, and is
  # not on the file's justified read-only list. Note what is absent — any notion of what
  # the method DOES with the path. Holding it is the violation.
  def violations_in(src, path: "(memory)", reads: {})
    code = strip_comments(src)
    methods = methods_in(code)
    raw = raw_producers(code, methods)

    found = methods.filter_map do |m|
      next if m.body =~ LAUNDER_RE
      next if reads.key?(m.name)

      reaches = (m.body =~ PATH_RE) ||
                raw.any? { |p| p != m.name && m.body =~ /\b#{Regexp.escape(p)}\b/ }
      next unless reaches

      "#{path}:#{m.line} #{m.name} — reaches a raw <projects>/.agents path without " \
        "TaskUsageSandbox.enforce! (what it DOES with the path is irrelevant — holding it is the violation)"
    end

    # TOP-LEVEL script code, outside any def — the region a method-only scan never looks
    # at, and a bin/ script's main body can mutate the store from there as easily as any
    # method can. It gets no exemption list, because it has no method NAME to declare and
    # nothing for a reviewer to hang a justification on. The rule is simply:
    #
    #   Top-level code may not reach a store path in any form that could ACT on it.
    #
    # The only tolerated forms are INERT ones — an assignment (`X = File.join(…, ".agents")`,
    # `dir ||= …`) and a hash-literal value (`registry: …`). Both merely NAME a path; a
    # value cannot delete a file. Everything else at top level — a call, a block, a
    # shell-out — is refused, and the fix is always the same: hoist it into a named
    # method, where it becomes either laundered or declared. That is why bin/task grew
    # `usage_audit_dir` in this PR: its store path used to sit inline in the dispatch.
    #
    # This grammar is THREE closed forms, checked positively — not a blacklist of the
    # things a top-level statement might do, which would be the SINK_RE mistake again.
    bodies = methods.map(&:body).join
    residual = code.lines.each_with_index.reject { |l, _| bodies.include?(l) }
    found + residual.filter_map do |line, i|
      reaches = (line =~ PATH_RE) || raw.any? { |p| line =~ /\b#{Regexp.escape(p)}\b/ }
      next unless reaches
      next if line =~ LAUNDER_RE || line =~ /^\s*(require|autoload)/
      next if line =~ /^\s*[A-Za-z_][\w.\[\]"'-]*\s*(\|\|=|=)[^=]/  # assignment — inert
      next if line =~ /^\s*[a-z_]\w*:\s/                            # hash-literal value — inert
      # visibility declaration — inert, and `private_class_method :marker_path` is the
      # very line that makes LAYER 2a hold. Refusing it would be refusing the fix.
      next if line =~ /^\s*(private_class_method|private|public|protected|module_function)\b/

      "#{path}:#{i + 1} top-level code reaches a raw <projects>/.agents path outside an inert " \
        "assignment. Hoist it into a named method, where it must be laundered or declared."
    end
  end

  # bin/** in ANY language (LAYER 1 must see bash) plus lib/**/*.rb.
  def scanned_sources
    files = Dir.glob(File.join(ROOT, "bin", "**", "*")) + Dir.glob(File.join(ROOT, "lib", "**", "*.rb"))
    files.select { |f| File.file?(f) && !File.symlink?(f) }
         .map { |f| [f.delete_prefix("#{ROOT}/"), File.read(f)] }
         .reject { |_, src| src.encoding == Encoding::BINARY }
  rescue ArgumentError
    files.map { |f| [f.delete_prefix("#{ROOT}/"), File.read(f)] }
  end

  def files_of_kind(*kinds)
    ALLOWED_CONSTRUCTORS.select { |_, (kind, _)| kinds.include?(kind) }.keys
  end

  # ── LAYER 1 — only these files may NAME the store, in any spelling ─────────────

  def test_unit_only_allowed_files_construct_a_path_under_the_real_agents_dir
    found = scanned_sources.filter_map { |path, src| path if strip_comments(src) =~ PATH_RE }.to_set

    unexpected = found - ALLOWED_CONSTRUCTORS.keys.to_set
    assert_empty unexpected.to_a,
                 "These files construct a path under the operator's real <projects>/.agents but are not " \
                 "sanctioned to.\nEvery such path must come from a guarded seam (TaskUsageSandbox.enforce!) " \
                 "or a guarded API (SessionMarkers.write/delete).\nIf this file genuinely must resolve the " \
                 "store, add it to ALLOWED_CONSTRUCTORS with the reason — and make sure LAYER 2 passes."

    # The other direction. Without this, renaming the store (or deleting the last real
    # constructor) leaves a test that passes because it now checks NOTHING.
    stale = ALLOWED_CONSTRUCTORS.keys.to_set - found
    assert_empty stale.to_a,
                 "ALLOWED_CONSTRUCTORS lists files that no longer construct a store path. Drop them — a " \
                 "stale allowlist is how this test quietly stops testing anything."
  end

  # ── LAYER 2 — and what they may DO with it ─────────────────────────────────────

  def test_unit_no_raw_state_store_path_is_held_unguarded_in_any_allowed_file
    violations = files_of_kind(:ruby).flat_map do |path|
      violations_in(File.read(File.join(ROOT, path)), path: path, reads: UNGUARDED_PATH_METHODS.fetch(path))
    end

    assert_empty violations,
                 "Raw <projects>/.agents path held without the guard:\n  " +
                 violations.join("\n  ") +
                 "\n\nRoute it through TaskUsageSandbox.enforce!(path, store: …) — or, for the narration " \
                 "markers, through SessionMarkers.write/delete, which enforce for you. If the method only " \
                 "READS the store, add it to UNGUARDED_PATH_METHODS with the reason. Note there is no list of " \
                 "IO verbs to grow: a shell-out is refused for holding the path, exactly like a File.write."
  end

  # UNGUARDED_PATH_METHODS is the entire exemption surface, so it gets the same anti-stale
  # equality LAYER 1 gets. A listed method that no longer holds a raw path is an
  # exemption sitting there with nothing to exempt — the next method to take its name
  # inherits a free pass nobody granted it.
  def test_unit_read_only_exemptions_are_not_stale
    stale = UNGUARDED_PATH_METHODS.flat_map do |path, reads|
      src = strip_comments(File.read(File.join(ROOT, path)))
      raw = raw_producers(src, methods_in(src))
      methods = methods_in(src)

      reads.keys.reject do |name|
        m = methods.find { |x| x.name == name }
        m && ((m.body =~ PATH_RE) || raw.any? { |p| p != name && m.body =~ /\b#{Regexp.escape(p)}\b/ })
      end.map { |name| "#{path}##{name}" }
    end

    assert_empty stale,
                 "These UNGUARDED_PATH_METHODS entries no longer reach a store path. Drop them — a stale " \
                 "exemption is a free pass waiting for the next method to take that name."
  end

  # The two allowlists must stay in lockstep. UNGUARDED_PATH_METHODS is `fetch`ed per
  # file, so adding a :ruby file to ALLOWED_CONSTRUCTORS forces its author to state its
  # exemptions — even if the honest answer is "none" — rather than inherit a silent {}.
  def test_unit_every_allowed_ruby_file_declares_its_exemption_surface
    assert_equal files_of_kind(:ruby).sort, UNGUARDED_PATH_METHODS.keys.sort,
                 "every LAYER 2 file must appear in UNGUARDED_PATH_METHODS (an empty hash is a valid, and " \
                 "the best, answer) — and an entry for a file that is no longer allowlisted is dead weight"
  end

  # Exactly one file may be exempt from LAYER 2 altogether, and it must be the guard.
  # Any second :guard entry is someone exempting themselves.
  def test_unit_the_only_layer_two_exemption_is_the_guard_itself
    assert_equal ["lib/task_usage_sandbox.rb"], files_of_kind(:guard),
                 "the guard is the ONLY file allowed to name .agents without laundering it — it is what " \
                 "DEFINES the forbidden root. A second entry here is a self-issued exemption."
  end

  # ── LAYER 2a — a raw path may not ESCAPE the file that built it ────────────────
  # The lemma LAYER 1 stands on. If a shared lib handed out a raw path, a caller could
  # File.delete(AgentApi.new.token_cache_path) and never type ".agents" — LAYER 1 would
  # never see it, and no widening of PATH_RE could ever fix that, because there is no
  # store name in the calling file to match. So the builders are private, and that is
  # asserted here rather than trusted to stay that way.

  def test_unit_no_shared_lib_exports_a_raw_store_path
    exported = Dir.glob(File.join(ROOT, "bin", "lib", "*.rb")).flat_map do |file|
      src = strip_comments(File.read(file))
      next [] unless src =~ PATH_RE

      methods = methods_in(src)
      producers = raw_producers(src, methods)
      private_names = src.scan(/private_class_method\s+:(\w+)|private\s+:(\w+)/).flatten.compact.to_set
      after_private = src.split(/^\s*private\s*$/, 2)[1].to_s
      producers.reject { |p| private_names.include?(p) || after_private =~ /^\s*def\s+(?:self\.)?#{Regexp.escape(p)}\b/ }
               .map { |p| "#{file.delete_prefix("#{ROOT}/")}##{p}" }
    end

    assert_empty exported,
                 "These shared libs EXPORT a raw <projects>/.agents path. A caller can take it and mutate the " \
                 "store without ever naming .agents — which LAYER 1 cannot see, in any spelling. Make the " \
                 "builder private (SessionMarkers#marker_path, AgentApi#token_cache_path) and export only a " \
                 "guarded seam:\n  " + exported.join("\n  ")
  end

  # ── LAYER 3 — the BOUNDARY receipt, for what no source scan can read ───────────
  # bin/statusline is bash. LAYER 2's Ruby method splitter cannot read one line of it,
  # and neither could ANY Ruby sink scan see the shell-outs it is made of. So its
  # containment is not asserted from source at all — it is OBSERVED. Run it armed and
  # unpinned, then look at the filesystem. A bash write, a shell-out, a subprocess: none
  # of them can hide from the store not changing.
  #
  # SAFE BY CONSTRUCTION. The child is given a session id minted FRESH for this
  # assertion, so it can never collide with a live session's markers — and the assertion
  # is a RECURSIVE glob of the real store for that id, not a check of one predicted
  # path, so a leak is caught wherever it lands rather than only where I guessed.

  def test_integration_bash_statusline_writes_nothing_to_the_real_store_when_unpinned
    id = "containment-#{SecureRandom.uuid}"
    payload = %({"session_id":"#{id}","workspace":{"current_dir":"#{ROOT}"}})

    Dir.mktmpdir do |home|
      env = ENV.to_h.merge("TASK_USAGE_SANDBOX" => "1", "HOME" => home)
      env.delete("CLAUDE_PROJECTS_DIR") # UNPINNED — the leak this family exists to close
      out, _err, _status = Open3.capture3(env, File.join(ROOT, "bin", "statusline"), stdin_data: payload)

      refute_empty out.strip, "the status line must still RENDER when it refuses to write — a refusal that " \
                              "also breaks the agent's prompt would just get the guard reverted"
    end

    leaked = Dir.glob(File.join(TaskUsageSandbox.real_state_dir, "**", "*#{id}*"), File::FNM_DOTMATCH)
    assert_empty leaked,
                 "bin/statusline wrote into the operator's REAL state store while sandboxed and unpinned. " \
                 "This is the lane that catches what no Ruby scan can: bash, shell-outs, subprocesses."
  end

  # ── the checker itself must be able to FAIL ────────────────────────────────────
  # A green architecture test is worthless if it is green because it finds nothing. Each
  # of these is a vector that walked straight through the FIRST draft of this test.

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
    assert_match(/clear_activity_usage_baselines/, found.join("\n"))
  end

  # THE VECTOR THAT DEFEATED THE FIRST DRAFT. A real bin/leaky-demo, with this exact
  # body, deleted the operator's live .open-activity marker and the containment suite
  # ran 6 / 0 failures — GREEN. No File.join, no marker_path: nothing for the old regex
  # to see. It is the ORDINARY way a Ruby author writes a path, which is what made it
  # the most dangerous miss in the file.
  def test_unit_layer_one_catches_the_ordinary_interpolated_path
    leaky = <<~'RUBY'
      def nuke(id)
        File.delete("#{projects_dir}/.agents/sessions/#{id}.open-activity")
      end
    RUBY

    assert_match PATH_RE, strip_comments(leaky),
                 "LAYER 1 must see the ORDINARY spelling of a path — plain interpolation. This is the vector " \
                 "the first draft of this test was blind to, in the file it exists to protect."
    refute_empty violations_in(leaky, path: "bin/leaky-demo")
  end

  # LAYER 2 has no sink list to be incomplete, so a shell-out is refused for the same
  # reason a File.write is: the method held the path. Both of these are INSIDE an
  # allowlisted file, where LAYER 1 free-passes and LAYER 2 is the only guard — which is
  # exactly where the old SINK_RE was the only thing standing, and leaked.
  def test_unit_layer_two_refuses_a_shell_out_it_was_never_taught_about
    shell = <<~'RUBY'
      def nuke(id)
        p = File.join(projects_dir, ".agents", "sessions", "#{id}.json")
        system("rm -rf #{p}")
      end
    RUBY

    found = violations_in(shell, path: "bin/task", reads: {})
    refute_empty found, "a shell-out cannot be seen by ANY Ruby sink scan. It is refused here because the " \
                        "method HOLDS the raw path — the verb is never inspected at all."
    assert_match(/nuke/, found.join("\n"))
  end

  # The vectors the review enumerated, plus the ones it did not — a Pathname receiver,
  # File.binwrite, backticks, FileUtils.rmtree, File.new(p,"w"), a constant indirection,
  # a nested File.join (whose close-paren the old [^)]* could not cross), and a joined
  # subpath. Not one of them is on any list in this file. They are refused as a CLASS,
  # by the only property they cannot avoid sharing: each had to name the store.
  def test_unit_layer_two_refuses_every_sink_spelling_because_it_inspects_none_of_them
    vectors = {
      "Pathname receiver" => 'p = File.join(d, ".agents", "s.json")
                              Pathname.new(p).delete',
      "File.binwrite" => 'p = File.join(d, ".agents", "s.json")
                          File.binwrite(p, "x")',
      "backticks" => 'p = File.join(d, ".agents", "s.json")
                      `rm -f #{p}`',
      "FileUtils.rmtree" => 'p = File.join(d, ".agents", "s.json")
                             FileUtils.rmtree(p)',
      "File.new(w)" => 'p = File.join(d, ".agents", "s.json")
                        File.new(p, "w").puts("x")',
      "joined subpath" => 'p = File.join(d, ".agents/sessions", "s.json")
                           IO.binwrite(p, "x")',
      "nested File.join" => 'p = File.join(File.expand_path(d), ".agents", "s.json")
                             File.write(p, "x")',
      "Open3 subprocess" => 'p = File.join(d, ".agents", "s.json")
                             Open3.capture3("shred", p)'
    }

    # The constant-indirection vector: the mutating method names NOTHING. It is caught by
    # taint from the constant, which is why constants are producers.
    const_vector = <<~'RUBY'
      SESSIONS = File.join(PROJECTS, ".agents", "sessions")

      def nuke(id)
        FileUtils.remove_entry_secure(File.join(SESSIONS, "#{id}.json"))
      end
    RUBY

    vectors.each do |name, body|
      src = "def nuke(id)\n  #{body}\nend\n"
      refute_empty violations_in(src, path: "bin/task"), "#{name} must be refused — it named the store"
    end

    refute_empty violations_in(const_vector, path: "bin/task"),
                 "a constant indirection hides the store name from the MUTATING method; taint from the " \
                 "constant is what closes it"
  end

  # MY OWN vector, on nobody's list — and the one that motivated LAYER 2a. This file
  # never types ".agents" and never calls marker_path. It asks an allowlisted lib for the
  # path and mutates it. NO widening of PATH_RE can catch this, because there is no store
  # name in this source to match — the only defence is that the lib cannot hand the path
  # out, which is what LAYER 2a asserts against the real tree.
  def test_unit_layer_two_a_is_what_stops_a_raw_path_being_borrowed_from_a_lib
    borrower = <<~RUBY
      def nuke(session_id)
        File.delete(AgentApi.new(open_timeout: 1, read_timeout: 1).token_cache_path)
      end
    RUBY

    assert_empty violations_in(borrower, path: "bin/leaky-import"),
                 "PROOF OF THE HOLE, not of the fix: this really is invisible to a source scan — it names " \
                 "nothing. LAYER 1 and LAYER 2 cannot ever catch it."

    # …so the containment comes from the OTHER end: the lib may not export the path at
    # all. That is asserted against the live tree in
    # test_unit_no_shared_lib_exports_a_raw_store_path — this is the same claim, checked
    # here against the two real builders so the two tests cannot drift apart.
    %w[bin/lib/agent_api.rb bin/lib/session_markers.rb].each do |lib|
      src = strip_comments(File.read(File.join(ROOT, lib)))
      producers = raw_producers(src, methods_in(src))
      after_private = src.split(/^\s*private\s*$/, 2)[1].to_s
      names = src.scan(/private_class_method\s+:(\w+)/).flatten.to_set

      producers.each do |p|
        assert names.include?(p) || after_private =~ /^\s*def\s+(?:self\.)?#{Regexp.escape(p)}\b/,
               "#{lib}##{p} returns a raw store path and is PUBLIC — a caller can borrow it and never name " \
               "the store, which no source scan can see"
      end
    end
  end

  def test_unit_scanner_passes_the_guarded_sibling_and_the_declared_read
    guarded = <<~RUBY
      def clear_acting_agent(session_id)
        SessionMarkers.delete(session_id, projects_dir, ACTING_AGENT, env: @api.env)
      end

      def write_feature_marker(task)
        path = TaskUsageSandbox.enforce!(feature_marker_path, store: "session-marker")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "x")
      end

      def feature_marker_path
        TaskUsageSandbox.enforce!(File.join(PROJECTS_DIR, ".agents", "sessions", "s.json"),
                                  store: "session-marker")
      end

      def read_marker(session_id)
        File.read(File.join(PROJECTS_DIR, ".agents", "sessions", "s.json"))
      end
    RUBY

    assert_empty violations_in(guarded, path: "bin/task", reads: { "read_marker" => "declared read" }),
                 "a laundered write, a guarded-API delete, and a DECLARED read are all legitimate"
  end

  def test_unit_scanner_finds_the_known_methods
    src = File.read(File.join(ROOT, "bin", "lib", "session_markers.rb"))
    names = methods_in(src).map(&:name)

    %w[marker_path write_path write delete read].each do |expected|
      assert_includes names, expected, "the method splitter missed #{expected} — the scan would be blind"
    end
  end
end

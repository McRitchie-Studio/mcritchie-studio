# frozen_string_literal: true

# THE CERT LABEL VOCABULARY IS A CLAIM ABOUT RUNNING CODE, and until this test
# existed nothing checked the prose against the emitters. A doc or a config
# comment that names a bracketed receipt is asserting "this is what the machine
# records"; when a lane is renamed or retired, every such sentence silently
# becomes a lie that reads exactly like the truth.
#
# MEASURED, 2026-09-08: config/release_repos.yml described turf-vault's cert path
# with a receipt one generation stale. Two of three sites were corrected in
# another repo, which left this one half-corrected: worse than uniformly stale,
# because a reader cannot tell which site is current.
#
# WHY THIS GUARD IS NOT A GREP FOR ONE LABEL. A literal grep finds the label it
# was written for and nothing the next time a DIFFERENT label goes stale. So the
# guard is keyed on the EMITTERS instead:
#
#   * the fingerprint-bound lanes come from CertEvidence::EVIDENCE_LANES — the
#     constant bin/control-check writes with (lib/cert_evidence.rb). Since DevOps v3
#     phase 2b (/tasks/retire-local-cert-evidence) that is ONE lane, `control`; the
#     fast-cert, full-suite, rubocop and cert-deferred receipts retired with the
#     scripts that wrote them, and this sweep is what keeps their spelling out of
#     every doc that would otherwise still promise them;
#   * the author hatches are SCRAPED from the scripts that honour them, by the
#     idiom they are honoured with (`\[\s*<label>\s*[\]:]`), so a hatch added to
#     bin/dor-check joins the vocabulary without editing this file;
#   * the fingerprint metavariable ("lane", as in `[lane@<fp>]`) is read off
#     CertEvidence.evidence_line's own parameter list rather than hard-coded.
#
# Rename a lane and every document that still names the old one goes red here.
#
# ITS LIMIT, STATED PLAINLY. The vocabulary scans prove a label EXISTS; they
# cannot prove a real label is used in the right PLACE, and no string check can
# detect an arbitrarily reworded false mechanism.
#
#   ruby -Itest test/docs/cert_label_vocabulary_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "../../lib/cert_evidence"
require_relative "../../bin/lib/release_registry"

class CertLabelVocabularyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # The documentation surface that makes claims about receipts: the registry
  # comments, the agent docs, the topic docs, and the scripts' own header prose.
  SWEPT_GLOBS = %w[config/*.yml docs/**/*.md bin/* bin/lib/*.rb lib/*.rb].freeze
  # Frozen snapshots. An audit or an archived doc is a record of what was true on
  # its date; correcting it would falsify the record (AGENTS.md house rule).
  EXCLUDED_PREFIXES = %w[docs/agents/archive/ docs/agents/audits/].freeze

  # FLOORS — a sweep whose glob stops matching passes having proved nothing. Set
  # under what is swept today (312 files on 2026-09-08; the receipt and label
  # counts fell with the retired lanes on 2026-09-24) but high enough that a glob
  # that silently resolves to a handful of files fails instead of certifying air.
  FILE_FLOOR = 200
  RECEIPT_FLOOR = 8
  LABEL_FLOOR = 3

  # A fingerprint-bound receipt as the code writes it: "[<lane>@<fingerprint>]",
  # optionally repo-scoped. CertEvidence.evidence_line builds exactly this shape.
  RECEIPT_RE = /\[\s*([a-z][a-z0-9-]*)\s*@([^\]\s]+)\]/
  # An email address in a bracketed rake argument — `bin/rails "email:smoke[a@b.com]"`
  # — is the same SHAPE and none of our business. A trailing TLD tells them apart.
  ADDRESS_RE = /\.[a-z]{2,}\z/
  # A bare hyphenated label: "[browser-bypass]". Single words are deliberately
  # out of scope — "[unit]", "[docs]", "[control]" are tier tags and markdown link
  # text, and sweeping them would drown the signal.
  BARE_LABEL_RE = /\[\s*([a-z][a-z0-9]*(?:-[a-z0-9]+)+)\s*\]/
  # How a script says "I honour this bracketed author record", as it appears in
  # the source: \[\s*browser-bypass\s*[\]:]
  HONORED_RE = /\\\[\\s\*([a-z][a-z0-9-]*)\\s\*\[\\\]:\]/

  # --- the vocabulary, derived from the code that runs ---------------------------

  def lanes
    CertEvidence::EVIDENCE_LANES
  end

  # The name the emitter itself gives the lane slot, so "[lane@<fp>]" in prose is
  # read as the placeholder it is rather than as a lane nobody records.
  def metavariable
    CertEvidence.method(:evidence_line).parameters.first.last.to_s
  end

  # Author hatches, scraped from whichever script honours them.
  def honored_hatches
    @honored_hatches ||= begin
      sources = (Dir.glob(File.join(ROOT, "bin/*")) +
                 Dir.glob(File.join(ROOT, "bin/lib/*.rb")) +
                 Dir.glob(File.join(ROOT, "lib/*.rb"))).select { |f| File.file?(f) }
      sources.flat_map { |f| read_swept(f).to_s.scan(HONORED_RE).flatten }.uniq
    end
  end

  def allowed_labels
    (lanes + honored_hatches).uniq
  end

  # Words the vocabulary is built from, so a NEW label sharing the namespace
  # ("cert-skipped", "suite-bypass") is inspected rather than ignored. `suite` and
  # `cert` are kept in the word set by hand: the lanes that carried them retired,
  # and a doc that resurrects a `[full-suite-…]` or `[…-cert]` label is exactly the
  # stale promise this sweep exists to catch.
  def vocabulary_words
    (allowed_labels.flat_map { |l| l.split("-") } + %w[suite cert]).uniq
  end

  def swept_files
    @swept_files ||= SWEPT_GLOBS
                     .flat_map { |g| Dir.glob(File.join(ROOT, g)) }
                     .uniq
                     .select { |f| File.file?(f) }
                     .map { |f| f.delete_prefix("#{ROOT}/") }
                     .reject { |f| EXCLUDED_PREFIXES.any? { |p| f.start_with?(p) } }
                     .sort
  end

  def each_swept_line
    swept_files.each do |rel|
      text = read_swept(File.join(ROOT, rel))
      next if text.nil?

      text.each_line.with_index do |line, i|
        yield rel, i + 1, line
      end
    end
  end

  # Read one listed file, tolerating EXACTLY ONE failure: the file was listed by the glob
  # and is gone by the time we open it (a test fixture's ensure, a parallel worker).
  # A SKIP IS NEVER SILENT: the vanished file is recorded and the floor test below
  # fails if any of them is a TRACKED file.
  def read_swept(path)
    File.read(path)
  rescue Errno::ENOENT
    rel = path.delete_prefix("#{ROOT}/")
    vanished_files << rel
    warn "cert-label sweep: skipped #{rel} — listed by the glob, gone before the read"
    nil
  end

  def vanished_files
    @vanished_files ||= []
  end

  # Which of these paths git TRACKS. ONE QUERY PER PATH: `git ls-files` aborts the
  # WHOLE batch on a single path outside the repository.
  def tracked_among(paths)
    paths.select do |rel|
      !IO.popen(["git", "-C", ROOT, "ls-files", "--", rel], err: File::NULL, &:read).to_s.strip.empty?
    end
  end

  def receipts
    found = []
    each_swept_line do |rel, no, line|
      line.scan(RECEIPT_RE) do |(label, rhs)|
        next if rhs =~ ADDRESS_RE
        next if label == metavariable

        found << [label, "#{rel}:#{no}"]
      end
    end
    found
  end

  def bare_labels
    words = vocabulary_words
    found = []
    each_swept_line do |rel, no, line|
      line.scan(BARE_LABEL_RE) do |(label)|
        next if (label.split("-") & words).empty?

        found << [label, "#{rel}:#{no}"]
      end
    end
    found
  end

  def script(name)
    File.readlines(File.join(ROOT, name))
  end

  # The turf-vault entry's comment block, from its key to the next repo key.
  def turf_vault_entry
    lines = script("config/release_repos.yml")
    start = lines.index { |l| l.match?(/\A  turf-vault:\s*\z/) }
    refute_nil start, "config/release_repos.yml no longer has a turf-vault entry"
    rest = lines[(start + 1)..] || []
    stop = rest.index { |l| l.match?(/\A  [a-z0-9_-]+:/) } || rest.size
    rest[0...stop].join
  end

  # --- the sweep actually happened -----------------------------------------------

  def test_a_file_that_vanishes_between_glob_and_read_does_not_crash_the_sweep
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transient")
      File.write(path, "[control@abc] present, then gone\n")
      File.delete(path)

      assert_nil read_swept(path), "a file gone before the read is skipped, not raised"
      assert_includes vanished_files.map { |rel| File.basename(rel) }, "transient"
    end
  end

  def test_the_vanished_file_guard_tells_tracked_files_from_transients
    assert_equal ["lib/cert_evidence.rb"], tracked_among(["lib/cert_evidence.rb", "no/such/file.rb"])
  end

  def test_the_sweep_read_the_tree_rather_than_an_empty_glob
    assert_operator swept_files.size, :>=, FILE_FLOOR,
                    "the sweep resolved #{swept_files.size} file(s) — a glob that stopped matching"
    assert_operator receipts.size, :>=, RECEIPT_FLOOR,
                    "only #{receipts.size} receipt(s) found — the receipt pattern stopped matching"
    assert_operator bare_labels.size, :>=, LABEL_FLOOR,
                    "only #{bare_labels.size} bare label(s) found — the label pattern stopped matching"
    receipts
    bare_labels
    tracked = tracked_among(vanished_files.uniq)
    assert_empty tracked, "tracked files vanished mid-sweep — the sweep did not read the tree: #{tracked.inspect}"
  end

  def test_the_vocabulary_is_derived_from_the_emitters_not_copied_here
    assert_equal ["control"], lanes,
                 "the machine-owned lanes must come from CertEvidence — the constant bin/control-check " \
                 "writes with. A second lane needs a writer and a reader; the cert receipts retired"
    assert_equal "lane", metavariable,
                 "the fingerprint metavariable is read off CertEvidence.evidence_line's signature"
    assert_includes honored_hatches, "browser-bypass",
                    "the hatch scrape must find the labels bin/dor-check honours; it found " \
                    "#{honored_hatches.inspect}"
  end

  # --- every documented label is one the code can actually record -----------------

  def test_every_fingerprinted_receipt_names_a_lane_the_code_records
    stale = receipts.reject { |(label, _)| lanes.include?(label) }

    assert_empty stale.map { |(label, site)| "#{site} names [#{label}@…]" },
                 "a documented receipt names a lane no emitter records. The lanes the code writes are " \
                 "#{lanes.inspect} (CertEvidence::EVIDENCE_LANES). The fast-cert, full-suite, rubocop and " \
                 "cert-deferred receipts retired with the local cert scripts (DevOps v3 phase 2b): " \
                 "describe them as history, in prose, never in the bracketed form the machine wrote."
  end

  def test_every_documented_cert_family_label_is_recorded_or_honoured_somewhere
    allowed = allowed_labels
    stale = bare_labels.reject { |(label, _)| allowed.include?(label) }

    assert_empty stale.map { |(label, site)| "#{site} names [#{label}]" },
                 "a documented label sits in the cert namespace but nothing records or honours it. " \
                 "Recorded: #{lanes.inspect}. Honoured hatches: #{honored_hatches.inspect}. (The " \
                 "full-suite-bypass hatch retired with the cert it bypassed.)"
  end

  # --- turf-vault's DECLARED lane ---------------------------------------------------

  def test_turf_vault_declares_a_lane
    assert ReleaseRegistry.registry_gated?("turf-vault"),
           "turf-vault must reach bin/fast-check's whole-gate branch. Without this it has a real " \
           "suite and no way for a builder to run it locally."
    refute_empty ReleaseRegistry.release_check_cmd("turf-vault").to_s,
                 "turf-vault's registry row declares no release_check command"
    refute ReleaseRegistry.registry_gated?("turf-monster"), "the control: a Rails app owes the Rails lanes"
  end

  # THE DECLARATION MUST STAY A SCRIPT THE REPO OWNS, AND THE PROSE MUST NAME IT.
  # The CI-parity check lives in the repo that owns both artifacts (turf-vault's
  # scripts/tests/release-check-covers-ci.test.js); this guard pins the hub's end:
  # a repo-owned script rather than a copy of someone else's CI, named in the prose.
  def test_turf_vault_entry_documents_the_gate_it_declares
    entry = turf_vault_entry
    declared = ReleaseRegistry.release_check_cmd("turf-vault").to_s

    refute_includes declared, "&&",
                    "turf-vault's row is spelling its lanes out again (#{declared.inspect}). A command chain " \
                    "here is a COPY of that repo's ci.yml living in this one, and it drifts."
    assert_match %r{\Abin/[\w.-]+\z}, declared,
                 "turf-vault's declared gate must be a script the REPO owns (got #{declared.inspect})"
    assert entry.include?(declared),
           "the turf-vault entry declares `#{declared}` but its prose never names it"
    assert entry.include?(TURF_VAULT_PARITY_GUARD),
           "the turf-vault entry no longer credits #{TURF_VAULT_PARITY_GUARD} with holding that script equal " \
           "to ci.yml; if the guard moved, say where it moved to."

    root = turf_vault_checkout
    return unless root

    script = root.join(declared)
    return unless script.file?

    assert script.stat.mode.anybits?(0o111),
           "#{script} is not executable, so the lane would die EACCES"
    guard = root.join(TURF_VAULT_PARITY_GUARD)
    assert guard.file?,
           "#{root} no longer carries #{TURF_VAULT_PARITY_GUARD}, the guard this row credits with keeping " \
           "`#{declared}` equal to that repo's ci.yml. Restore it, or rewrite this entry to say so."
  end

  TURF_VAULT_PARITY_GUARD = "scripts/tests/release-check-covers-ci.test.js"

  # Walk up from THIS repo's toplevel looking for a projects root that holds
  # turf-vault, resolved by its ci.yml so an unrelated directory cannot answer.
  def turf_vault_checkout
    Pathname.new(ROOT).ascend do |dir|
      candidate = dir.join("turf-vault")
      return candidate if candidate.join(".github", "workflows", "ci.yml").file?
    end
    nil
  end
end

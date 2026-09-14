# frozen_string_literal: true

# THE CERT LABEL VOCABULARY IS A CLAIM ABOUT RUNNING CODE, and until this test
# existed nothing checked the prose against the emitters. A doc or a config
# comment that names a cert receipt is asserting "this is what the machine
# records"; when a lane is renamed or a new door is added, every such sentence
# silently becomes a lie that reads exactly like the truth.
#
# MEASURED, 2026-09-08: config/release_repos.yml described turf-vault's cert path
# as a "[full-suite-bypass]" — one generation stale, because bin/fast-check now
# records "[cert-deferred@<fp>]" there — AND it blamed the wrong mechanism ("the
# Rails prepare lane aborts the run first"; the deferral is decided at the
# SELECTION and exits before any lane runs). Two of the three sites of that same
# stale label were corrected in turf-vault PR #28 (03dd5bb), which left this repo
# half-corrected: worse than uniformly stale, because a reader cannot tell which
# site is current.
#
# WHY THIS GUARD IS NOT A GREP FOR "[full-suite-bypass]". That string is still a
# LEGITIMATE, live author hatch (FullSuiteGate::BYPASS_TAG) — the defect was using
# it for the wrong path, not the term existing. A literal grep would have found
# the label, left the false-mechanism sentence standing beside the corrected one,
# and caught nothing the next time a DIFFERENT label went stale. So the guard is
# keyed on the EMITTERS instead:
#
#   * the fingerprint-bound lanes come from CertEvidence::EVIDENCE_LANES — the
#     same constant bin/fast-check and bin/full-suite-check write their receipts
#     with (lib/cert_evidence.rb, loaded by bin/lib/full_suite_gate.rb);
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
# detect an arbitrarily reworded false mechanism. That half is covered
# structurally instead, by pinning the prose's factual claims to source ORDER
# (test_fast_check_* / test_full_suite_check_*): if fast-check ever decides the
# deferral after a lane, or full-suite-check stops leading with bin/rails, these
# go red and the sentences that describe them must be rewritten. The sentence
# check below is a narrow backstop for the exact causal claim that was wrong, not
# a general false-prose detector.
#
#   ruby -Itest test/docs/cert_label_vocabulary_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "../../lib/cert_evidence"
require_relative "../../bin/lib/full_suite_gate"

class CertLabelVocabularyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # The documentation surface that makes claims about cert receipts: the registry
  # comments, the agent docs, the topic docs, and the scripts' own header prose.
  SWEPT_GLOBS = %w[config/*.yml docs/**/*.md bin/* bin/lib/*.rb lib/*.rb].freeze
  # Frozen snapshots. An audit or an archived doc is a record of what was true on
  # its date; correcting it would falsify the record (AGENTS.md house rule).
  EXCLUDED_PREFIXES = %w[docs/agents/archive/ docs/agents/audits/].freeze

  # FLOORS — a sweep whose glob stops matching passes having proved nothing. Set
  # comfortably under what is swept today (312 files / 76 receipts / 23 labels on
  # 2026-09-08) so ordinary churn does not trip them, but high enough that a glob
  # that silently resolves to a handful of files fails instead of certifying air.
  FILE_FLOOR = 200
  RECEIPT_FLOOR = 50
  LABEL_FLOOR = 15

  # A fingerprint-bound receipt as the code writes it: "[<lane>@<fingerprint>]",
  # optionally repo-scoped. CertEvidence.evidence_line builds exactly this shape.
  RECEIPT_RE = /\[\s*([a-z][a-z0-9-]*)\s*@([^\]\s]+)\]/
  # An email address in a bracketed rake argument — `bin/rails "email:smoke[a@b.com]"`
  # — is the same SHAPE and none of our business. A trailing TLD tells them apart.
  ADDRESS_RE = /\.[a-z]{2,}\z/
  # A bare hyphenated label: "[full-suite-bypass]". Single words are deliberately
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
    (lanes + [FullSuiteGate::BYPASS_TAG] + honored_hatches).uniq
  end

  # Words the vocabulary is built from, so a NEW label sharing the namespace
  # ("cert-skipped", "suite-waived") is inspected rather than ignored.
  def vocabulary_words
    allowed_labels.flat_map { |l| l.split("-") }.uniq
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
  # and is gone by the time we open it (a test fixture's ensure, a parallel worker). Both
  # read sites above go through here, because both had the race.
  #
  # A SKIP IS NEVER SILENT. The vanished file is recorded (vanished_files) and printed, and
  # the floor test below fails if any of them is a TRACKED file: a tracked file vanishing
  # mid-suite means the sweep did not read the tree, and a green here would certify air —
  # the failure this file's floors already exist to stop. Only an untracked transient may
  # be skipped. Every other error still raises.
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

  # Which of these paths git TRACKS. A vanished tracked file is not a transient.
  # ONE QUERY PER PATH, deliberately: `git ls-files` aborts the WHOLE batch on a single
  # path outside the repository and prints nothing, which would make this guard answer
  # "none tracked" for every file in that batch — a guard that passes by reading nothing.
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

  # ── A FILE THAT VANISHES BETWEEN THE GLOB AND THE READ ──────────────────────
  #
  # THE RACE, from CI job 102764654211 (rails (4), 2399 runs, 1 ERROR):
  #   Errno::ENOENT … bin/fast-check-crash-fixture  (cert_label_vocabulary_test.rb, readlines)
  # test/lib/fast_check_test.rb used to write that fixture BESIDE the real bin/fast-check
  # and delete it in an ensure. Under parallel workers this sweep's glob listed it and
  # the read found it gone. It landed on whichever PR happened to be running, blocked the
  # green-CI-only review pop, and sat red for ~5 hours on a PR it had nothing to do with.
  #
  # Reproduced here DETERMINISTICALLY, with the file created and deleted between the
  # listing and the read — outside the repo, so this test is not a second copy of the
  # hazard it pins. The path is expressed relative to ROOT, exactly as the glob yields it.
  def test_a_file_that_vanishes_between_glob_and_read_does_not_crash_the_sweep
    Dir.mktmpdir("cert-label-vanish") do |dir|
      path = File.join(dir, "fast-check-crash-fixture")
      File.write(path, "cert: crash-fixture\n")
      rel = Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
      @swept_files = [rel] # the glob listed it...
      File.delete(path)    # ...and the fixture's ensure removed it before the read

      lines = []
      each_swept_line { |f, no, line| lines << [f, no, line] }

      assert_empty lines, "a vanished file has no lines to sweep"
      assert_includes vanished_files, rel,
                      "and it is NAMED, not silently dropped — a scan that skipped a file without " \
                      "saying so would read as a clean scan of a tree it never finished reading"
    end
  end

  # The guard that keeps a skip honest must itself discriminate, or it is decoration: a
  # tracked script is named, an untracked transient is not, and a transient in the same
  # batch cannot blind the query for the tracked one.
  def test_the_vanished_file_guard_tells_tracked_files_from_transients
    assert_equal ["bin/fast-check"], tracked_among(["bin/fast-check"])
    assert_empty tracked_among(["bin/fast-check-crash-fixture"])
    assert_equal ["bin/fast-check"], tracked_among(["../outside-the-repo", "bin/fast-check"])
  end

  def test_the_sweep_read_the_tree_rather_than_an_empty_glob
    assert_operator swept_files.size, :>=, FILE_FLOOR,
                    "the label sweep matched only #{swept_files.size} files — a glob has stopped " \
                    "resolving, so a green here proves nothing. Globs: #{SWEPT_GLOBS.inspect}"
    assert_operator receipts.size, :>=, RECEIPT_FLOOR,
                    "only #{receipts.size} fingerprinted receipts were swept (floor #{RECEIPT_FLOOR}); " \
                    "the receipt pattern has stopped matching the documented shape"
    assert_operator bare_labels.size, :>=, LABEL_FLOOR,
                    "only #{bare_labels.size} cert-family labels were swept (floor #{LABEL_FLOOR}); " \
                    "the label pattern or the derived vocabulary has stopped matching"
    honored_hatches # the second read site, so its skips are counted here too
    tracked = tracked_among(vanished_files)
    assert_empty tracked,
                 "TRACKED files vanished between the glob and the read: #{tracked.join(', ')}. The sweep " \
                 "did not read the tree, so this green would prove nothing. Only untracked transients " \
                 "may be skipped (read_swept)."
  end

  def test_the_vocabulary_is_derived_from_the_emitters_not_copied_here
    assert_includes lanes, CertEvidence::DEFER_LANE,
                    "the deferral lane must come from CertEvidence, the constant the cert scripts write with"
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
                 "#{lanes.inspect} (CertEvidence::EVIDENCE_LANES). Correct the prose, or add the lane " \
                 "to the constant if it is genuinely new."
  end

  def test_every_documented_cert_family_label_is_recorded_or_honoured_somewhere
    allowed = allowed_labels
    stale = bare_labels.reject { |(label, _)| allowed.include?(label) }

    assert_empty stale.map { |(label, site)| "#{site} names [#{label}]" },
                 "a documented label sits in the cert namespace but nothing records or honours it. " \
                 "Recorded: #{lanes.inspect}. Honoured hatches: " \
                 "#{([FullSuiteGate::BYPASS_TAG] + honored_hatches).uniq.inspect}."
  end

  # --- the mechanism the prose describes, pinned to source order ------------------

  def test_fast_check_decides_the_deferral_before_any_lane_runs
    src = script("bin/fast-check")
    defer = src.index { |l| l.include?("FullSuiteGate::DEFER_LANE") }
    exit_at = src.index { |l| l.match?(/exit\s+FastCert::DEFERRED_EXIT/) }
    # A call, not the definition: `def run_lane(label,` has no quote after the paren.
    first_lane = src.index { |l| l.match?(/run_lane\("/) }

    refute_nil defer, "bin/fast-check no longer emits the deferral receipt"
    refute_nil exit_at, "bin/fast-check no longer exits on the deferral"
    refute_nil first_lane, "bin/fast-check no longer runs any lane"
    assert_operator defer, :<, first_lane,
                    "bin/fast-check now decides its deferral AFTER a lane has run (receipt at line " \
                    "#{defer + 1}, first lane at #{first_lane + 1}). Every doc that says the deferral " \
                    "is decided before any lane — config/release_repos.yml's turf-vault entry among " \
                    "them — is now wrong and must be rewritten."
    assert_operator exit_at, :<, first_lane,
                    "bin/fast-check's deferral no longer exits before its first lane (exit at line " \
                    "#{exit_at + 1}, first lane at #{first_lane + 1})"
  end

  def test_full_suite_check_is_the_script_that_needs_bin_rails
    src = script("bin/full-suite-check")
    first = src.find { |l| l.match?(/run_lane\("/) }
    refute_nil first, "bin/full-suite-check no longer runs any lane"

    assert_match(/run_lane\("test-db-reset"/, first,
                 "bin/full-suite-check's FIRST lane is no longer the test-DB reset — the claim that it " \
                 "is the script that meets the missing bin/rails must be re-verified and the prose fixed")

    reset_cmd = src.join[/FULL_SUITE_TEST_DB_RESET_CMD",\s*"([^"]+)"/, 1]
    refute_nil reset_cmd, "bin/full-suite-check no longer declares a default test-DB reset command"
    assert_includes reset_cmd, "bin/rails",
                    "bin/full-suite-check's first lane no longer shells out to bin/rails"

    # THE CLAIM IS ABOUT A REPO THAT STILL OWES THE RAILS LANE. It used to name
    # turf-vault, which stopped being an example on 2026-09-14: turf-vault now
    # DECLARES a release_check, so full-suite-check skips its reset lane too
    # (skip_test_db_reset reads registry_gated?, not gem_repo?). Asserting the old
    # fact would have kept passing — turf-vault is still not a gem — while the
    # sentence it vouched for had become false. turf-monster is the control: a real
    # Rails app, declaring nothing, which must keep meeting this lane.
    refute FullSuiteGate.registry_gated?("turf-monster"),
           "turf-monster now declares its own gate, so full-suite-check SKIPS its bin/rails lane and " \
           "this script is no longer the one that meets the missing runner — re-verify the prose"
    assert FullSuiteGate.registry_gated?("turf-vault"),
           "turf-vault no longer declares a cert lane. It has a real suite (56/56 node:test, plus both " \
           "Rust lanes), so an absent declaration means builders are back to having no way to certify " \
           "it — the exact gap /tasks/cert-lane-owner-is-archived closed"
  end

  # --- the site that was wrong, and the distinction it must keep ------------------

  # --- turf-vault's DECLARED cert lane -------------------------------------------
  #
  # This slot used to assert the entry named CertEvidence::DEFER_LANE, because the
  # honest description of turf-vault's cert path was "it defers before any lane".
  # That stopped being true on 2026-09-14, when the row declared a `release_check`
  # and bin/fast-check started keying its whole-gate branch on the DECLARATION
  # rather than on the `gems` section. The deferral guard is not weakened, it is
  # RELOCATED: the label vocabulary tests above still pin CertEvidence::DEFER_LANE
  # to its emitter for every repo that does defer.

  def test_turf_vault_declares_a_cert_lane
    assert FullSuiteGate.registry_gated?("turf-vault"),
           "turf-vault must reach bin/fast-check's whole-gate branch. Without this it has a real " \
           "suite and no way for a builder to run it, and the docs drift back to routing readers " \
           "at a task to go and decide — which is how this pointed at an ARCHIVED task for months."

    cmd = FullSuiteGate.release_check_cmd("turf-vault").to_s
    refute_empty cmd, "turf-vault's registry row declares no release_check command"
  end

  # THE ENTRY MUST DOCUMENT THE COMMAND IT DECLARES. A `&&` chain in a YAML scalar
  # is easy to extend and easy to leave undescribed, and this row's prose is what a
  # reader trusts about what the cert covers. Keyed on the chain's own members, so
  # adding a lane to the command without describing it fails HERE.
  def test_turf_vault_entry_documents_every_lane_it_declares
    entry = turf_vault_entry
    lanes = FullSuiteGate.release_check_cmd("turf-vault").to_s.split("&&").map(&:strip)

    assert_operator lanes.size, :>=, 2, "expected a multi-lane chain, got #{lanes.inspect}"
    lanes.each do |lane|
      # The distinguishing token, not the whole invocation: the prose names lanes
      # readably ("cargo clippy", "test:scripts") rather than quoting every flag.
      token = lane[/\b(?:npm run |yarn )?([a-z][a-z0-9:_-]*)/i, 1]
      subject = lane.include?("cargo") ? lane.split[0, 2].join(" ") : token
      assert entry.include?(subject),
             "the turf-vault entry declares `#{lane}` but its prose never mentions #{subject.inspect} — " \
             "a reader cannot tell what this repo's cert actually covers"
    end
  end

  # DRIFT, MEASURED WHERE IT CAN BE. The declared chain is a hub-side copy of
  # turf-vault's own CI lanes, because that repo ships no bin/release-check for the
  # registry to point at. If ci.yml gains or renames a lane, this string does not
  # follow it and the cert silently covers less than CI does.
  #
  # ITS LIMIT, STATED PLAINLY: this reads a SIBLING checkout, so it can only run
  # where one exists. It resolves from any ancestor of Rails.root (which is how it
  # works from a worktree desk, whose parent is `.worktrees`, not the projects
  # root) and SKIPS when turf-vault is not checked out — as on hub CI, which clones
  # this repo alone. It is a local tripwire for the builder editing either side,
  # not a CI gate, and must not be described as one.
  def test_turf_vault_cert_lane_covers_its_ci_lanes_when_the_checkout_is_readable
    ci = turf_vault_ci_workflow
    skip "turf-vault is not checked out beside this repo — drift cannot be measured here" unless ci

    declared = FullSuiteGate.release_check_cmd("turf-vault").to_s
    # Every `run:` step in the workflow, reduced to the command it invokes.
    runs = ci.scan(/^\s*run:\s*(.+)$/).flatten.map(&:strip)
    covered = runs.select { |r| r.start_with?("npm run", "cargo check", "cargo clippy") }

    refute_empty covered,
                 "turf-vault's ci.yml no longer runs any of the lanes this cert declares — the " \
                 "declared chain must be re-derived from the workflow"
    covered.each do |run_cmd|
      # `npm run <script>` needs THREE words to identify a lane — two would reduce
      # every npm step to "npm run" and quietly cover a script CI added and this
      # chain does not run. `cargo <subcommand>` is identified by two.
      subject = run_cmd.split[0, run_cmd.start_with?("npm run") ? 3 : 2].join(" ")
      assert declared.include?(subject),
             "turf-vault's CI runs `#{run_cmd}` and the declared cert lane does not cover #{subject.inspect}. " \
             "config/release_repos.yml's release_check has drifted from .github/workflows/ci.yml; " \
             "re-derive it (or give the repo a bin/release-check and point the row at that)."
    end
  end

  # Walk up from Rails.root looking for a projects root that holds turf-vault. A
  # worktree desk sits two levels below the hub primary, so Rails.root.parent is
  # `.worktrees` and the naive sibling lookup finds nothing.
  def turf_vault_ci_workflow
    Pathname.new(Rails.root).ascend do |dir|
      candidate = dir.join("turf-vault", ".github", "workflows", "ci.yml")
      return candidate.read if candidate.file?
    end
    nil
  end

  def test_turf_vault_entry_keeps_the_author_hatch_distinct_from_the_deferral
    entry = turf_vault_entry

    assert entry.include?(FullSuiteGate::BYPASS_TAG),
           "the #{FullSuiteGate::BYPASS_TAG} hatch is still live and must be DISTINGUISHED from the " \
           "deferral here, not erased"
    assert_match(/NOT A BYPASS/i, entry,
                 "the entry must say plainly that the deferral is not the bypass — that conflation is " \
                 "the defect this guard exists for")
  end

  def test_turf_vault_entry_does_not_blame_the_prepare_lane_for_the_deferral
    # The exact causal claim that was false: the run does not reach a prepare lane
    # before deferring. A descriptive "the prepare lane aborts the run" (true on the
    # OTHER path) is deliberately not matched.
    refute_match(/because the[^.]{0,40}prepare lane aborts/i, turf_vault_entry,
                 "the turf-vault entry blames a Rails prepare lane for the deferral. It cannot: " \
                 "bin/fast-check decides the deferral before any lane runs (see " \
                 "test_fast_check_decides_the_deferral_before_any_lane_runs). bin/full-suite-check is " \
                 "the script that meets the missing bin/rails.")
  end
end

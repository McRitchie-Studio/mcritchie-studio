# frozen_string_literal: true

require "yaml"

# bin/lib/fast_cert.rb — test SELECTION for the G1 fast cert (bin/fast-check).
#
# The 90/10 rethink of local certification: GitHub CI already runs the FULL
# suite (+ test:system) on every PR push, and bin/dor-check blocks on CI green —
# so a ~6-minute local `bin/rails test` before handoff bought EARLINESS, not
# coverage. The fast cert keeps the earliness (catch the obvious break in ~1
# minute, before the commit/push round-trip) and leans on CI as the full net.
#
# This module is the PURE selection half — mapping a branch diff to the test
# files worth running — so it unit-tests directly (require it, call functions)
# without spawning the runner. bin/fast-check owns orchestration: lanes, gate
# emits, fingerprint-bound evidence.
#
# Selection = union of three sets:
#   1. CONVENTION — each changed file maps to its test by path convention
#      (app/models/x.rb → test/models/x_test.rb, views → their controller test,
#      bin/tool → test/lib/tool_test.rb, a changed *_test.rb includes itself),
#      PLUS — for a tool whose twin lives in test/lib/ — its whole test FAMILY,
#      the test/lib/<stem>_<aspect>_test.rb siblings that are nobody else's twin.
#   2. GREP FALLBACK — a changed .rb file with NO existing convention target
#      falls back to a word-boundary grep of its class name (or a bin script's
#      name, or a config file's basename) across test/**/*_test.rb.
#   3. SPINE — config/fast_cert_spine.yml, a curated always-run core (critical
#      model/flow tests, ~10-15s) so a diff that maps to nothing still exercises
#      the money paths. Entries may be files or directories; missing paths are
#      skipped (a satellite worktree runs the hub's script but not its spine).
#
# And ONE degradation, because sets 1+2 are unbounded and the lane is not: past
# DEFAULT_MAPPED_CAP the mapped lane falls back to the CONVENTION TWINS ALONE
# (set 1 without the family hop and without set 2) rather than to nothing — see
# #convention_twins for why "to nothing" was a cliff and what the fallback costs.
module FastCert
  # app/<layer>/<rest>.rb → test/<layer>/<rest>_test.rb for these layers
  # (nested paths carry through: app/controllers/api/v1/x_controller.rb →
  # test/controllers/api/v1/x_controller_test.rb).
  APP_LAYERS = %w[models controllers helpers jobs mailers services channels commands].freeze

  module_function

  # --- changed-file collection (mirrors bin/dor-check's changed_files) --------
  # Union of the three base-independent working-tree views (staged, unstaged,
  # untracked) + the committed diff against the release-aware base — so the
  # selection is the same whether the cert runs pre- or post-commit.
  def changed_files(root, base)
    files = []
    [
      %w[diff --cached --name-only],
      %w[diff --name-only],
      %w[ls-files --others --exclude-standard]
    ].each do |args|
      files.concat(capture(["git", "-C", root.to_s, *args]).split("\n"))
    end
    committed = capture(["git", "-C", root.to_s, "diff", "--name-only", "#{base}...HEAD"])
    files.concat(committed.split("\n"))
    files.map(&:strip).reject(&:empty?).uniq
  end

  # origin/accepted when it exists (post-v2 branches are cut off `accepted`), else
  # origin/release, else origin/main — same three-tier default as bin/dor-check.
  def default_diff_base(root)
    %w[origin/accepted origin/release].each do |ref|
      ok = system("git", "-C", root.to_s, "rev-parse", "--verify", ref,
                  out: File::NULL, err: File::NULL)
      return ref if ok
    end
    "origin/main"
  rescue SystemCallError
    "origin/main"
  end

  # --- convention mapping ------------------------------------------------------
  # One changed path → its candidate test paths (existence NOT checked here; the
  # caller filters against the repo). Unmappable paths (docs, assets, db/) return
  # [] and rely on the grep fallback + spine.
  def convention_candidates(path)
    return [path] if path.match?(%r{\Atest/.+_test\.rb\z})

    case path
    when %r{\Aapp/views/(.+)/[^/]+\z}
      # A view/partial exercises through its controller (or mailer) test:
      # app/views/tasks/_gates.html.erb → test/controllers/tasks_controller_test.rb;
      # app/views/task_mailer/ping.html.erb → test/mailers/task_mailer_test.rb.
      dir = Regexp.last_match(1)
      ["test/controllers/#{dir}_controller_test.rb", "test/mailers/#{dir}_test.rb"]
    when %r{\Aapp/(#{APP_LAYERS.join("|")})/(.+)\.rb\z}
      ["test/#{Regexp.last_match(1)}/#{Regexp.last_match(2)}_test.rb"]
    when %r{\A(?:bin/)?lib/(.+)\.rb\z}
      # lib/foo.rb AND bin/lib/foo.rb → test/lib/foo_test.rb.
      ["test/lib/#{Regexp.last_match(1)}_test.rb"]
    when %r{\Abin/([^/]+)\z}
      # bin/fast-check → test/lib/fast_check_test.rb (the harness-test seam).
      ["test/lib/#{Regexp.last_match(1).tr('-', '_')}_test.rb"]
    else
      []
    end
  end

  # --- the test FAMILY hop -----------------------------------------------------
  # A tool's tests are a FAMILY, not a twin. test/lib/ is a flat namespace named
  # after the TOOL under test, and any tool big enough to matter grows suffixed
  # siblings: bin/dor-check has test/lib/dor_check_test.rb AND fourteen
  # dor_check_<aspect>_test.rb files. The convention hop above found the twin and
  # stopped, and because the grep fallback fires ONLY when the twin is MISSING,
  # those fourteen were unreachable from a diff touching bin/dor-check alone.
  #
  # THE EXPENSIVE HALF IS WHAT WAS MISSED. Among the fourteen is
  # dor_check_exempt_ci_test.rb, which holds a self-checking registry over
  # bin/dor-check's own source — so the one test guaranteed to notice a new call
  # site was the one test the local cert could never run. Measured 2026-09-06:
  # `FAST_CHECK_CHANGED_FILES=bin/dor-check bin/fast-check --list` returned 1
  # mapped path out of 15, and PR #1236's first push learned the difference from
  # CI instead of from the builder's cert.
  #
  # SCOPED TO test/lib/ DELIBERATELY, and this is the whole reason it is safe:
  # test/<layer>/ mirrors app/<layer>/ one file to one file, so a prefix sibling
  # THERE is a different subject's test — test/models/task_event_test.rb belongs
  # to app/models/task_event.rb, not to task.rb. Only the harness namespace names
  # its files after a tool rather than after a class, so only there does a prefix
  # sibling constitute evidence about the same subject.
  def family_tests(root, path, targets)
    # A changed test file is its own subject. Expanding it would drag thirteen
    # unrelated siblings into a one-line test edit.
    return [] if path.match?(%r{\Atest/.+_test\.rb\z})

    Array(targets).flat_map { |target| harness_family(root, target) }.uniq
  end

  # The existing test/lib/<stem>_<suffix>_test.rb siblings of an existing twin,
  # minus the ones that are somebody else's twin (see owned_elsewhere?).
  #
  # THE SCOPE IS STATED ONCE — in the regex below; the glob is built from the
  # matched TARGET rather than re-naming "test/lib/". Stated twice, the two
  # guards covered for each other: widening the regex alone changed nothing
  # because the glob still pinned the directory, so the test that should have
  # caught an over-wide scope stayed green against that mutation.
  def harness_family(root, target)
    return [] unless target.match?(%r{\Atest/lib/.+_test\.rb\z})

    stem = target.sub(/_test\.rb\z/, "")
    Dir.glob("#{stem}_*_test.rb", base: root.to_s)
       .reject { |sibling| owned_elsewhere?(root, sibling) }
       .sort
  end

  # PREFIX IS NOT PARENTHOOD. bin/lib/desk_ledger.rb's stem prefixes
  # test/lib/desk_ledger_import_test.rb — but that file is the twin of
  # bin/lib/desk_ledger_import.rb, a source file of its own that the diff did not
  # touch. Claiming it would run an unrelated tool's tests on every desk_ledger
  # edit, which is the over-widening this hop has to avoid to be worth having. A
  # sibling joins the family only when NO source file of its own exists.
  #
  # Measured over this repo 2026-09-07, sweeping EVERY source that convention-maps
  # into test/lib/ (bin/* + bin/lib/**/*.rb + lib/**/*.rb — 95 of them have an
  # existing twin): the glob finds 26 distinct candidate siblings, the guard rejects
  # THREE, and 23 genuine ones are kept.
  #
  #   test/lib/desk_ledger_import_test.rb   ← bin/lib/desk_ledger_import.rb
  #   test/lib/agent_worktree_cli_test.rb   ← bin/lib/agent_worktree_cli.rb
  #   test/lib/importmap_audit_ci_test.rb   ← bin/importmap-audit-ci
  #
  # THE EARLIER NUMBERS HERE ("sixteen candidates / rejects exactly two / keeps
  # fourteen") WERE WRONG ON ALL THREE, and the way they went wrong is worth keeping:
  # they SPLICED TWO INCOMPATIBLE SWEEPS. Sixteen is the candidate count of a bin/*-ONLY
  # sweep — which rejects exactly ONE (agent_worktree_cli_test.rb) — while
  # desk_ledger_import_test.rb is only reachable from the bin/lib sweep, which finds 9
  # candidates and rejects 2. No single sweep rejects two AND finds sixteen. The GUARD
  # was always right; only the prose lied, which is the failure mode of a measured
  # comment nobody re-derives. Re-derive before editing this paragraph, don't paste it.
  def owned_elsewhere?(root, test_path)
    source_twins(test_path).any? { |src| File.file?(File.join(root, src)) }
  end

  # The inverse of the test/lib/ half of convention_candidates: every source path
  # that would convention-map TO this test file. Existence is the caller's test.
  def source_twins(test_path)
    return [] unless test_path =~ %r{\Atest/lib/(.+)_test\.rb\z}

    stem = Regexp.last_match(1)
    ["lib/#{stem}.rb", "bin/lib/#{stem}.rb", "bin/#{stem}", "bin/#{stem.tr('_', '-')}"]
  end

  # The word this file's grep fallback hunts for across test/: a class name for
  # a .rb file (gate_run.rb → GateRun), the script name for a bin tool
  # (bin/fast-check → "fast-check", how harness tests reference it), the bare
  # basename for a config file (config/fast_cert_spine.yml → "fast_cert_spine").
  # nil = no fallback for this path (views/docs/assets rely on the spine).
  def grep_token(path)
    case path
    when %r{\Abin/([^/]+)\z} then Regexp.last_match(1)
    when /\.rb\z/ then camelize(File.basename(path, ".rb"))
    when %r{\Aconfig/.+\.ya?ml\z} then File.basename(path).sub(/\.ya?ml\z/, "")
    end
  end

  def camelize(str)
    str.to_s.split(/[_\-]/).map { |part| part.sub(/\A[a-z]/) { |c| c.upcase } }.join
  end

  # Every test file under root whose text mentions `token` as a whole word.
  # Read-in-Ruby (not shell grep) for BSD/GNU portability and determinism.
  def grep_tests(root, token)
    return [] if token.to_s.strip.empty?

    re = /\b#{Regexp.escape(token)}\b/
    Dir.glob("test/**/*_test.rb", base: root.to_s).select do |rel|
      File.read(File.join(root, rel)).match?(re)
    rescue StandardError
      false
    end
  end

  # PER CHANGED FILE, what it maps to: its EXISTING convention targets, or the
  # grep fallback when it has none. Returns { changed_path => [test paths] }.
  #
  # Exposed separately from select_tests because WHICH FILE mapped widely is the
  # only actionable detail when the mapping explodes. A cap that says "48 files,
  # too many" sends the builder looking through their whole diff; one that says
  # "config/initializers/studio.rb alone mapped 44" names the cause, and the cause
  # is almost always a single file whose grep token is too generic to mean
  # anything. Same passes as select_tests did — the union is computed from this,
  # so nothing is read twice.
  def mapping(root, changed)
    Array(changed).to_h do |path|
      existing = convention_candidates(path).select { |t| File.file?(File.join(root, t)) }
      tests =
        if existing.empty?
          grep_tests(root, grep_token(path))
        else
          (existing + family_tests(root, path, existing)).uniq
        end
      [path, tests]
    end
  end

  # The diff-mapped test set: the union of the above. Sorted + deduped, paths
  # relative to root.
  def select_tests(root, changed)
    mapping(root, changed).values.flatten.uniq.sort
  end

  # --- the cap's FALLBACK: the convention twins ----------------------------------
  #
  # WHAT THE CAP USED TO DO WHEN IT TRIPPED: skip the mapped lane WHOLESALE. So
  # crossing the cap was a CLIFF, not a slope — one file over and the lane ran ZERO
  # mapped tests, where the same diff minus that file ran fifteen. Measured on this
  # repo 2026-09-06/07:
  #
  #   bin/dor-check alone                      15 mapped → the lane ran 15
  #   bin/dor-check + bin/lib/ci_status.rb     16 mapped → the lane ran 0
  #
  # THE SECOND ROW IS WORSE THAN BEFORE THE FAMILY HOP EXISTED, which ran the two
  # twins. A widening that leaves some diffs with LESS than they had is not monotone,
  # and this one is not a corner case: bin/dor-check maps to exactly the cap, so any
  # multi-file diff touching the file the whole gate depends on landed on the wrong
  # side of it. That is what this fallback fixes — the widening is now monotone-good
  # at every family size, because the floor never drops below the pre-widening set.
  #
  # THE FALLBACK IS THAT PRE-WIDENING SET: each changed file's EXISTING convention
  # target — 1-2 paths per file — and nothing else. Not a new contract; it is the set
  # the fast lane ran on for months, so its cost and its coverage are both known.
  #
  # THE GREP FALLBACK IS DELIBERATELY EXCLUDED, and that exclusion is the only reason
  # this fallback is BOUNDED. The cap exists BECAUSE of the grep: a diff touching
  # config/initializers/studio.rb has no convention target, falls through to a
  # word-boundary grep of "Studio", matched 48 test files and ran 39m34s (2026-08-15).
  # Degrading to "twins OR grep" would re-run the exact explosion the cap was built to
  # stop. So a changed file with no twin contributes NOTHING here — which is the right
  # answer, not a gap: a grep matching half the suite was never evidence ABOUT that
  # file, and the cap already said so.
  #
  # WHICH CAUSE ACTUALLY TRIPS THE CAP — measured 2026-09-07 over all 474 mappable
  # hub sources, because the answer decides whether this fallback is a slope or just
  # a shorter cliff:
  #
  #   23 sources ALONE exceed the cap. All 23 are GREP-driven. ZERO are family-driven.
  #   Widest FAMILY mapping in the repo: bin/dor-check at 15 — AT the cap, never over
  #   it alone. Next widest family: 3.
  #   Widest GREP mappings: bin/task 325 ("task"), bin/release 257,
  #   config/environments/test.rb 208 ("Test"), bin/setup 198, bin/gate 176.
  #
  # So the family hop trips the cap only IN COMBINATION with a co-changed file — the
  # cliff above — while every single-file cap trip is a grep precision failure. And
  # this is what makes the fallback a slope rather than a shorter cliff, provably:
  # ALL 23 grep-driven cap-trippers have ZERO convention twins, so the fallback takes
  # nothing from them and they degrade to the spine exactly as they do today.
  # Truncating 39 arbitrary grep matches to 15 arbitrary grep matches would be a
  # shorter cliff; falling back to the TWIN is a slope. The grep's precision is a
  # separate defect and is deliberately NOT addressed here.
  #
  # Existence is checked here (unlike convention_candidates, which is pure) because
  # the caller needs a runnable lane, not a candidate list.
  def convention_twins(root, changed)
    Array(changed).flat_map { |path| convention_candidates(path) }
                  .select { |t| File.file?(File.join(root.to_s, t)) }
                  .uniq.sort
  end

  # HOW MANY MAPPED TESTS THIS LANE WILL RUN BEFORE IT IS WORTH RUNNING AT ALL.
  #
  # There was no cap, and a fast lane that can silently become a full suite is
  # worse than a slow one: the builder cannot tell which they are in. Observed
  # live on 2026-08-15 — a diff touching config/initializers/studio.rb mapped to
  # 48 test files and bin/fast-check was still running at 39m34s against a lane
  # that g1-cert.md budgets at about one minute. bin/ship runs this by default, so
  # every builder pays it.
  #
  # An initializer has no convention candidate, so it falls through to a
  # word-boundary grep of its camelized name — and "Studio" appears across the
  # whole tree. A grep that matches half the suite has told you nothing about
  # which tests are RELEVANT; it has only told you the token is too generic. Past
  # the cap the honest move is to stop pretending the mapping is a signal, run the
  # spine, and say so loudly.
  #
  # 15 is deliberately low. The lane's value is being predictable, not thorough —
  # bin/full-suite-check is one command away and is the right answer for a diff
  # this broad.
  DEFAULT_MAPPED_CAP = 15

  # THE DEFERRAL'S EXIT STATUS — the whole signal, and deliberately NOT 0.
  #
  # Every existing caller reaches bin/fast-check through `system(...)`, whose truthiness
  # is "exited 0". A deferral is NOT a certification, so it must stay FALSY there: any
  # caller that has not been taught about deferral keeps treating it exactly as it treats
  # a refusal, which is the safe reading. Only bin/ship reads the STATUS and knows that
  # this particular non-zero means "carry on to the PR, the fence is at step 7".
  #
  # Exiting 0 here would have been a one-line change and would have recreated PR #1226's
  # bug one rung along: a green-looking cert over zero executed tests.
  DEFERRED_EXIT = 2

  def mapped_cap
    raw = ENV["FAST_CHECK_MAPPED_CAP"].to_s.strip
    return DEFAULT_MAPPED_CAP if raw.empty?

    n = raw.to_i
    n.positive? ? n : DEFAULT_MAPPED_CAP
  end

  # The cap decision for an already-spine-deduped mapped set.
  #
  # APPLIED AFTER THE SPINE DEDUPE, deliberately: the cap is about how much EXTRA
  # work this lane does, and a mapped test the spine already runs costs nothing.
  # Capping the raw union would trip on diffs whose mapping is entirely redundant.
  #
  # Returns a Hash rather than a bare Boolean because the caller has to explain
  # itself: the cap it applied, how far over, the file to look at, and — since the
  # cliff fix — WHAT THE LANE WILL RUN INSTEAD.
  #
  # `twins` is the already-spine-deduped convention-twin set (#convention_twins);
  # it is passed IN rather than computed here so this stays a pure decision over
  # sets, unit-testable without a tree. Callers that do not supply it get the old
  # behaviour exactly: no twins, so an empty fallback, so a capped lane runs nothing.
  #
  # :fallback IS THE ONE PLACE THE ANSWER LIVES. Four consumers need to agree about
  # what a capped lane runs — the lane runner, the --list preview, the evidence line,
  # and the zero-evidence guard — and in PR #1239 a scope stated TWICE let a mutation
  # survive because each statement covered for the other. So it is computed once, here,
  # and every consumer reads this key rather than re-deriving it.
  #
  # THE FALLBACK IS CAPPED BY THE SAME NUMBER IT FELL BACK FROM, and this is what
  # keeps the slope from being a second cliff of its own. Twins are 1-2 paths per
  # CHANGED FILE, so a 60-file diff has ~60 of them — the unbounded lane the cap
  # exists to bound. The degradation therefore has three rungs, each governed by one
  # number: full mapped set → convention twins → spine only. A fallback that is itself
  # over the cap degrades again rather than buying itself an exemption.
  def cap_decision(mapped_only, breakdown, cap: mapped_cap, twins: [])
    worst = Array(breakdown).max_by { |_path, tests| Array(tests).size }
    capped = mapped_only.size > cap
    fallback = capped ? Array(twins).uniq.sort : []
    # WHAT THE FALLBACK WEIGHED, kept beside what it CHOSE, because the two empty
    # fallbacks are different facts and a receipt that cannot tell them apart is a
    # shrug: 0 considered means no changed file HAS a twin, while N > cap means the
    # twins were themselves too broad and the lane degraded a second time. It is 0
    # when the cap did NOT trip — there was nothing to weigh — so read it only
    # beside :capped.
    considered = fallback.size
    fallback = [] if fallback.size > cap

    {
      capped: capped,
      cap: cap,
      count: mapped_only.size,
      fallback: fallback,
      fallback_considered: considered,
      worst_path: worst && worst[0],
      worst_count: worst ? Array(worst[1]).size : 0
    }
  end

  # --- the zero-evidence guard ----------------------------------------------------
  #
  # WHAT THIS CERT WILL ACTUALLY EXECUTE, as a set of test PATHS. Both lanes that can
  # run tests are consulted: the mapped lane — EMPTY when the cap above skipped it —
  # and the spine.
  #
  # STATED LIMIT: this counts paths SELECTED, not test cases executed. A selected file
  # that happens to contain no test cases still counts here, because seeing that needs
  # the runner's own output. This guard needs only the selection, which is why it can be
  # decided before a single lane runs.
  #
  # THE ONE LINE THE TWINS FALLBACK CHANGES, and it is worth being precise about what
  # it does and does not touch, because getting this wrong re-opens PR #1226's
  # fail-green one rung further along.
  #
  #   UNCHANGED: the KEYING. The guard below still fires on ZERO EXECUTED TESTS and
  #   never on the cap — deliberately, since a diff mapping to 26 files must not be
  #   refused while a diff mapping to NONE certifies on rubocop alone.
  #
  #   CHANGED: the INPUT. A capped lane used to contribute [] here because it ran
  #   nothing. It now contributes its convention twins, because it RUNS them. The
  #   guard is not being loosened; it is being told the truth about what will run.
  #
  # The consequence is exactly the one intended, and it is a TIGHTENING of evidence,
  # never a loosening: a run that would previously have executed zero tests (capped
  # over an empty spine → a DEFERRAL) now executes its twins and certifies — on MORE
  # evidence than the deferral had, not less. And when the fallback is empty too (an
  # unmappable diff, or twins that are themselves over the cap), the executed set is
  # byte-identical to before and the run defers or refuses exactly as it did.
  def executed_test_paths(mapped_only, spine, cap)
    ran_mapped = cap && cap[:capped] ? Array(cap[:fallback]) : Array(mapped_only)
    (ran_mapped + Array(spine)).uniq
  end

  # A CERT THAT EXECUTES ZERO TESTS MUST NOT REPORT GREEN.
  #
  # Live on turf-monster PR #549, 2026-09-05, verbatim from checks_run:
  #
  #   fast cert green: 0 mapped (CAPPED: 26 > 15; spine only) + 0 spine test path(s),
  #   rubocop on 3 changed file(s)
  #
  # Read it slowly. The mapped lane was capped, so it announced a fallback to the spine;
  # the spine then resolved to ZERO paths. Nothing ran. The one executed check was
  # rubocop — a linter, which cannot observe behaviour — and the gate printed "green".
  # Three of five builds that night degraded this way, and every reviewer had to be told
  # by hand to weight CI over the G1 cert. A gate whose verdict needs a verbal caveat is
  # not a gate.
  #
  # WHY THE GUARD IS KEYED ON ZERO EXECUTED TESTS AND NOT ON THE CAP. The cap is one door
  # into this room, not the room. Keyed on the cap, a satellite diff that maps to 26 test
  # files would be refused while a satellite diff that maps to NONE — strictly LESS
  # evidence — would still certify green on rubocop alone. That ordering is incoherent, and
  # the second door is not hypothetical: config/fast_cert_spine.yml is anchored in the hub
  # and NONE of its entries exist in turf-monster or rolio, so on either satellite the spine
  # is always empty and the mapped lane is the only lane that can run a test at all.
  #
  # WHAT IT DELIBERATELY DOES NOT DO: it does not degrade a capped run that still ran a
  # spine. That run executed real tests, and its evidence line already says "0 mapped
  # (CAPPED: ...)" beside a loud MAPPED LANE CAPPED narration — it is a NARROWER cert,
  # honestly labelled, which is what the cap was designed to produce. Refusing it too
  # would degrade builds that legitimately certified.
  #
  # THE CAP ITSELF IS UNTOUCHED. This changes what a capped run REPORTS, never how much it
  # runs — an uncapped mapped lane on a broad diff is the ~31-minute local suite the fast
  # lane exists to avoid.
  #
  # WHERE THE REFUSAL LANDS IS NOT WHERE IT HELPS, and that is what this tri-state fixes.
  #
  # bin/fast-check runs at ship STEP 2 OF 8 — before the push, before the PR, before any CI
  # exists. So the refusal above, correct as a verdict, left the builder holding a diff with
  # NO PR and exactly one remedy: a local full suite, MEASURED at ~30 minutes against CI's ~9
  # for the identical command. That is the wall-clock the fast lane was built to avoid, and a
  # build paid it in full on 2026-09-06.
  #
  # AND IT IS A SATELLITE CONDITION, NOT A CAP CONDITION — which is why the split below keys
  # on the ZERO and merely READS the cap, rather than keying on the cap itself.
  # config/fast_cert_spine.yml has five entries and ALL FIVE exist only in the hub (measured
  # 2026-09-06: turf-monster 0 of 5, rolio 0 of 5). So one capped diff splits two ways, both
  # observed the same day:
  #
  #   HUB       release-offers-retired-cert — bin/release.rb mapped 50 files, 51 paths over
  #             the cap → mapped lane skipped → THE SPINE STILL RAN → certified green and
  #             accepted against a green CI. The cap cost coverage, not the PR. Untouched here.
  #   SATELLITE empty-solana-network-fails-open (turf-monster) — 29 paths over the cap →
  #             mapped lane skipped → spine resolves to NOTHING → zero executed tests →
  #             REFUSED, and the builder paid the ~30 minutes.
  #
  # The population that needs the deferral is therefore the six non-hub repos, and a fix that
  # moved the HUB half would be over-broad. Nothing below can reach a run that executed a test.
  #
  # THE TWO ZERO-EVIDENCE CASES ARE NOT THE SAME FACT, and separating them is the whole idea:
  #
  #   CAPPED  → :defer. Reached only when the spine ALSO resolved to nothing, i.e. on a
  #             satellite. The diff DID map to real, relevant test files — MORE than the cap,
  #             not fewer. Every one of them runs on CI, on this exact tree, in the run that
  #             was going to happen anyway. Nothing about the evidence is missing; only the
  #             RUNNER is wrong, and we chose that ourselves for a budget reason. So the cert
  #             defers: it records a fingerprint-bound receipt saying no local lane could
  #             certify this tree, and dor-check credits that receipt ONLY beside a GREEN CI.
  #
  #   UNMAPPED → :refuse, unchanged and byte-identical. Here the diff maps to NOTHING: no
  #             convention target, no grep hit, no spine. That is a fact about the DIFF — the
  #             suite contains nothing that reads this code — and it is worth telling the
  #             builder rather than routing around. Deferring it would be deleting the guard
  #             for one of its two doors, not relocating its evidence.
  #
  # DEFERRING IS NOT SKIPPING. The refusal is not weakened; it MOVES, from step 2 to step 7,
  # where dor-check owns it. A red CI, an absent CI, a CI nobody could read, and a receipt gone
  # stale under a later edit all still refuse the submit — and they refuse it with the PR open,
  # which is the only place the evidence could ever have come from.
  #
  # THE CAP ITSELF IS UNTOUCHED, and so is every run that executes a test. A capped run with a
  # live spine, and every ordinary diff, return nil here exactly as before.
  #
  # Returns nil when at least one test path will run, or a Hash the caller acts on:
  #   { kind: :refuse, message: } — abort (the caller prefixes "fast-check: ")
  #   { kind: :defer,  message:, detail: } — record the receipt, exit DEFERRED
  def zero_test_outcome(mapped_only, spine, cap, slug: nil)
    return nil unless executed_test_paths(mapped_only, spine, cap).empty?

    task = slug.to_s.strip.empty? ? "<task>" : slug.to_s.strip
    return defer_outcome(cap, task) if cap && cap[:capped]

    { kind: :refuse, message: refuse_message(task) }
  end

  # The UNMAPPED refusal — the half that does not move. Kept verbatim from the guard PR
  # 1226 added, because the case it describes has not changed.
  def refuse_message(task)
    "REFUSING TO CERTIFY — this run would execute ZERO test files, so there is nothing to " \
      "certify. the diff maps to NO test file — no convention target, and no word-boundary " \
      "grep hit, and this checkout resolves NO spine entries (the spine list is " \
      "anchored in the hub; a satellite checkout resolves none of it). That leaves rubocop " \
      "as the only lane, and a linter cannot observe behaviour — a green cert here would be " \
      "a verdict on evidence that does not exist. Run the cert that DOES cover this diff:" \
      "\n    bin/full-suite-check #{task}"
  end

  # The CAPPED deferral. `detail` is what goes on the recorded receipt — it must name the
  # cap, the count and the culprit, because a receipt nobody can read back to a cause is how
  # a deferral becomes a shrug. `message` is what the builder reads, and it says the two
  # things they need: nothing was certified here, and what has to be true later.
  def defer_outcome(cap, task)
    culprit = cap[:worst_path] ? " (widest: #{cap[:worst_path]} → #{cap[:worst_count]} test file(s))" : ""
    detail = "cert DEFERRED to GitHub CI: the mapped lane was CAPPED — #{cap[:count]} mapped " \
             "path(s) over the cap of #{cap[:cap]}#{culprit} — over a spine this checkout " \
             "resolves NONE of, so NO local lane could certify this tree. #{fallback_note(cap)} " \
             "CI runs the full " \
             "suite on this exact code; bin/dor-check credits this receipt only alongside a " \
             "GREEN CI, never provisionally."
    message =
      "NOT CERTIFIED — DEFERRING to GitHub CI. This run would execute ZERO test files: " \
      "#{detail}" \
      "\n  What happens next: bin/ship pushes and opens the PR anyway, waits for CI, and " \
      "bin/dor-check REFUSES the submit unless CI is GREEN. A red CI, no CI, or an edit " \
      "after this receipt all still block — deferring is not skipping." \
      "\n  Prefer to certify locally instead? bin/full-suite-check #{task}" \
      "\n  (or run the mapped lane anyway, deliberately: FAST_CHECK_MAPPED_CAP=#{cap[:count]} " \
      "bin/fast-check #{task} — that is the broad local suite this cap exists to avoid.)"
    { kind: :defer, message: message, detail: detail }
  end

  # WHY THE TWINS FALLBACK DID NOT SAVE THIS RUN — the clause that keeps the deferral
  # receipt a complete explanation now that "capped" has a rung under it. Reaching a
  # deferral means the cap tripped AND the fallback came up empty, and the receipt has
  # to say which of the two empties it was or a reader cannot tell a diff that maps to
  # nothing from one whose twins were too broad.
  def fallback_note(cap)
    considered = cap[:fallback_considered].to_i
    if considered > cap[:cap].to_i
      "The convention-twin fallback did not save it either: #{considered} twin(s) is ITSELF over " \
        "the cap of #{cap[:cap]}, so the lane degraded a second time, to the spine."
    else
      "The convention-twin fallback was empty too — no changed file has an existing test twin " \
        "(the fallback deliberately excludes the grep, which is what the cap is protecting you from)."
    end
  end

  # --- spine --------------------------------------------------------------------
  # The curated always-run core from config/fast_cert_spine.yml. Entries may be
  # files or directories; only ones that exist under root survive (the hub's
  # spine list silently no-ops in a satellite checkout).
  def spine(root, config_path)
    data = YAML.safe_load(File.read(config_path.to_s)) || {}
    Array(data["spine"]).map(&:to_s).select { |p| File.exist?(File.join(root, p)) }
  rescue Errno::ENOENT, Psych::SyntaxError
    []
  end

  # Mapped tests already covered by a spine entry (exact file, or inside a spine
  # directory) are dropped from the mapped lane so nothing runs twice.
  def covered_by_spine?(test_path, spine_entries)
    Array(spine_entries).any? { |s| test_path == s || test_path.start_with?("#{s}/") }
  end

  # --- rubocop scope --------------------------------------------------------------
  # The changed files rubocop can actually lint: ruby by extension/name, plus bin
  # scripts with a ruby shebang. Deleted files are skipped (nothing to lint).
  RUBY_PATH_RE = /\.(rb|rake|gemspec|ru)\z/
  RUBY_BASENAMES = %w[Gemfile Rakefile config.ru].freeze

  def lintable_files(root, changed)
    Array(changed).select do |path|
      full = File.join(root, path)
      next false unless File.file?(full)
      next true if path.match?(RUBY_PATH_RE) || RUBY_BASENAMES.include?(File.basename(path))

      path.start_with?("bin/") && ruby_shebang?(full)
    end
  end

  def ruby_shebang?(full)
    File.open(full) { |f| f.gets }.to_s.include?("ruby")
  rescue StandardError
    false
  end

  def capture(argv)
    IO.popen(argv, err: File::NULL, &:read).to_s
  rescue SystemCallError
    ""
  end
end

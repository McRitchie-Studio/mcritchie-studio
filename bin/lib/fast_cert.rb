# frozen_string_literal: true

require "yaml"
require_relative "code_diff"
require_relative "fast_lane"

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
# Selection = union of the spine and a per-file mapping, and the mapping is three
# rungs ORDERED BY HOW DIRECTLY EACH NAMES THE SUBJECT:
#   1. CONVENTION — each changed file maps to its test by path convention
#      (app/models/x.rb → test/models/x_test.rb, views → their controller test,
#      bin/tool → test/lib/tool_test.rb OR test/commands/tool_test.rb, a changed
#      *_test.rb includes itself), PLUS — for a tool whose twin lives in a harness
#      namespace — its whole test FAMILY, the <stem>_<aspect>_test.rb siblings that
#      are nobody else's twin.
#   2. ORPHAN FAMILY — a tool whose same-named twin was NEVER WRITTEN still reaches
#      that family. bin/task has no test/lib/task_test.rb, so rung 1 found nothing
#      and rung 3 asked for the word "task" and claimed 325 of the repo's 622 test
#      files. See #orphan_family.
#   3. GREP — anything still unmapped falls back to a search for the SUBJECT'S
#      IDENTITY across test/**/*_test.rb: for a FILE its path, plus the other
#      spelling the codebase actually writes — a script's quoted command name, a
#      config's quoted basename, and (for an initializer) the constant it wires when
#      this repo defines it; for a CLASS its FULL constant. Not the basename as an
#      English word, which is what made rung 3 the source of every cap trip in the
#      repo. See #grep_tokens.
#   +. SPINE — config/fast_cert_spine.yml, a curated always-run core (critical
#      model/flow tests, ~10-15s) so a diff that maps to nothing still exercises
#      the money paths. Entries may be files or directories; missing paths are
#      skipped (a satellite worktree runs the hub's script but not its spine).
#
# WHAT THE PRECISION RUNGS ARE WORTH, measured over all 1928 hub sources 2026-09-07
# (head 3e678a19): 27 sources ALONE mapped over the 15-path cap and all 27 were
# rung-3 greps; after, 9 do. Across the 160 sources the grep could reach, the total
# mapped paths fall 2778 → 701. 1832 of the 1928 sources map BYTE-IDENTICALLY.
#
# WHAT THE CONFIG SECOND SPELLING COSTS, swept the same way — both rule sets run over
# the SAME tree, all 1929 tracked sources, 2026-09-07 — because a widening is only as
# good as its blast radius and this file has been over-widened twice:
#
#   1925 of 1929 sources map BYTE-IDENTICALLY
#   the 4 that move all GAIN; NOT ONE source loses a path
#   cap-trippers 9 → 9, the identical nine sources, none of them a config
#   total grep-reachable paths 627 → 632
#
# The four are config/initializers/edge_guard.rb (gains BOTH edge-guard tests),
# config/rails_lane.yml (its contract test), config/qa_environments.yml (its permanent
# guard) and config/e2e_lane.yml. Swept on THIS branch, whose own tests name those
# configs; on `accepted` the same sweep reads 618 → 623 and edge_guard 0 → 2, which is
# the number that states the defect.
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

  # The SAME three-plus-one views as #changed_files, but as the RENAME-AWARE path
  # list — both sides of every R/C entry (CodeDiff.paths_from_name_status).
  #
  # THIS IS NOT AN ALTERNATIVE SPELLING OF #changed_files, and the difference is a
  # documented fail-green. `--name-only` collapses `R100 bin/deploy.sh docs/notes.md`
  # to `docs/notes.md`, so a commit that RENAMES AN EXECUTABLE INTO A .md presents as
  # one prose file while having deleted a script from bin/. #changed_files is for test
  # SELECTION, where the destination is the right answer (the old path has no tests to
  # run); this view is for CLASSIFICATION, where the old path is half the change. See
  # the "BOTH SIDES OF A RENAME" block in bin/lib/code_diff.rb.
  #
  # Used by the no-suite-owed waiver in bin/fast-check, which must never call a diff
  # doc-only on the strength of a path the rename invented.
  #
  # WHAT `-M` IS AND IS NOT DOING HERE, measured rather than assumed (2026-09-07): it
  # is NOT the safety. `diff.renames` defaults to TRUE, and with detection OFF git
  # emits the pair as `D bin/deploy.sh` + `A notes.md` — BOTH paths, which classifies
  # identically. So dropping `-M` is an equivalent mutation and no test can bite on it.
  # It is here to pin the parse shape `CodeDiff.paths_from_name_status` documents
  # (`--name-status -M`) and to make this view independent of the reader's git config
  # rather than incidentally correct under it. What IS load-bearing is `--name-status`:
  # switch this to `--name-only` and the parse yields NOTHING (its lines carry one
  # field), which reads as an unobservable diff and — fail-closed — refuses.
  def classifiable_paths(root, base)
    paths = []
    [
      %w[diff --cached --name-status -M],
      %w[diff --name-status -M]
    ].each do |args|
      paths.concat(CodeDiff.paths_from_name_status(capture(["git", "-C", root.to_s, *args])))
    end
    # Untracked files have no status line — they are plain paths, and a rename cannot
    # hide in them (git has never seen the file before).
    paths.concat(capture(["git", "-C", root.to_s, "ls-files", "--others", "--exclude-standard"]).split("\n"))
    paths.concat(
      CodeDiff.paths_from_name_status(
        capture(["git", "-C", root.to_s, "diff", "--name-status", "-M", "#{base}...HEAD"])
      )
    )
    paths.map(&:strip).reject(&:empty?).uniq
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
      #
      # THE `.rb` IS STRIPPED because a test filename never carries one mid-stem.
      # bin/release.rb is the only top-level bin/*.rb in the repo, and it used to
      # ask for `test/lib/release.rb_test.rb` — a path no convention in this repo
      # would ever produce, so it could not exist, so the file fell to the grep on
      # the literal token "release.rb" and matched 51 files (2026-09-07). Stripped,
      # it asks for test/lib/release_test.rb like bin/release does, and reaches the
      # same subject's family. No source with an EXISTING twin changes: the only
      # path this clause moves is one whose old target could not exist.
      #
      # BOTH HARNESS NAMESPACES, because there are two and the mapper only knew one.
      # test/commands/ holds 31 files (2026-09-07) named after the tool under test
      # exactly as test/lib/ is — test/commands/session_kickoff_test.rb builds
      # `File.join(ROOT, "bin", "session-kickoff")` and drives it. Eleven of them are
      # the exact twin of a bin script and were INVISIBLE to this hop, so their tools
      # were pushed onto the grep and matched on an English word instead
      # (bin/setup → "setup" → 198 files, while test/commands never came up).
      stem = Regexp.last_match(1).sub(/\.rb\z/, "").tr("-", "_")
      ["test/lib/#{stem}_test.rb", "test/commands/#{stem}_test.rb"]
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
  # SCOPED TO THE HARNESS NAMESPACES DELIBERATELY — test/lib/ and test/commands/ —
  # and this is the whole reason it is safe:
  # test/<layer>/ mirrors app/<layer>/ one file to one file, so a prefix sibling
  # THERE is a different subject's test — test/models/task_event_test.rb belongs
  # to app/models/task_event.rb, not to task.rb. Only a harness namespace names
  # its files after a tool rather than after a class, so only there does a prefix
  # sibling constitute evidence about the same subject.
  def family_tests(root, path, targets)
    # A changed test file is its own subject. Expanding it would drag thirteen
    # unrelated siblings into a one-line test edit.
    return [] if path.match?(%r{\Atest/.+_test\.rb\z})

    Array(targets).flat_map { |target| harness_family(root, target) }.uniq
  end

  # --- the family hop for a tool whose TWIN IS MISSING ---------------------------
  #
  # THE FAMILY HOP ABOVE IS GATED ON THE TWIN EXISTING, and that gate is what sent
  # the widest sources in the repo to the grep. bin/task has no test/lib/task_test.rb
  # — nobody ever wrote the same-named file — so `existing` was empty, the family hop
  # never ran, and the fallback grep asked for the word "task" and got 325 files.
  # Meanwhile test/lib/task_begin_test.rb, task_cli_test.rb and
  # task_events_backfill_test.rb sat right there, named after the tool, unreachable.
  #
  # A MISSING TWIN IS NOT A MISSING SUBJECT. test/lib/ names its files after the TOOL
  # under test, so the family is evidence about the tool whether or not one of its
  # members happens to carry the bare name. Measured 2026-09-07, this is worth 325 → 3
  # for bin/task, 176 → 1 for bin/gate, 153 → 2 for bin/rails, 39 → 2 for
  # bin/pr-review, 257 → 21 for bin/release.
  #
  # SAME GLOB, SAME OWNERSHIP GUARD — deliberately #harness_family itself rather than
  # a second implementation of it, so the scope is stated ONCE and a mutation to the
  # rule cannot be covered for by a copy that still holds. That is the failure PR #1239
  # hit when its scope was stated twice.
  #
  # A CHANGED TEST FILE IS EXCLUDED for the same reason #family_tests excludes it: a
  # DELETED test/lib/foo_test.rb would otherwise have no existing twin and drag its
  # whole family into a diff that removed it.
  def orphan_family(root, path)
    return [] if path.match?(%r{\Atest/.+_test\.rb\z})

    convention_candidates(path).flat_map { |target| harness_family(root, target) }.uniq
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
    return [] unless target.match?(%r{\Atest/(?:lib|commands)/.+_test\.rb\z})

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
    case test_path
    when %r{\Atest/lib/(.+)_test\.rb\z}
      stem = Regexp.last_match(1)
      ["lib/#{stem}.rb", "bin/lib/#{stem}.rb", "bin/#{stem}", "bin/#{stem.tr('_', '-')}"]
    when %r{\Atest/commands/(.+)_test\.rb\z}
      # ONLY the bin forms. A library under lib/ or bin/lib/ convention-maps to
      # test/lib/, never to test/commands/, so treating one as the OWNER of a
      # commands file would reject a genuine sibling that nobody owns — the guard
      # firing on a source that could not have produced this path.
      stem = Regexp.last_match(1)
      ["bin/#{stem}", "bin/#{stem.tr('_', '-')}"]
    else
      []
    end
  end

  # --- the grep hop's SUBJECT REFERENCE ------------------------------------------
  #
  # WHAT THE GREP IS ASKING, and what it used to ask instead. The question worth
  # asking is "which tests are ABOUT this file?", and a test is about a subject when
  # it NAMES that subject the way the codebase names it. The old token asked a much
  # weaker question — "which tests contain this file's basename as a word?" — and a
  # basename is not a name. Measured over all 1191 mappable hub sources 2026-09-07:
  #
  #   bin/task                     → "task"     → 325 test files (of 622 in the repo)
  #   bin/release                  → "release"  → 257
  #   config/environments/test.rb  → "Test"     → 208
  #   app/services/news/review.rb  → "Review"   → 39, and NOT ONE of them was about it
  #
  # The last row is the clearest: the constant that file defines is `News::Review`.
  # `Review` is not a shorter spelling of it — it is a different token that the class
  # is never referred to by, so all 39 matches were coincidence. 27 sources ALONE
  # exceeded the 15-path cap and every one of them was a grep like these.
  #
  # SO THE TOKEN IS THE SUBJECT'S IDENTITY, and identity has two forms here:
  #
  #   A FILE is identified by its PATH. A harness test names bin/fast-check as
  #   "bin/fast-check", and a config test names config/queue.yml as
  #   "config/queue.yml". Neither is ever referred to as the bare word "fast-check"
  #   or "queue" — those are English, and English is what matched 325 files.
  #
  #   A CLASS is identified by its CONSTANT — the FULL one. Rails autoloads
  #   app/<layer> as a root, so app/services/news/review.rb is `News::Review` and
  #   app/controllers/api/v1/x_controller.rb is `Api::V1::XController`. Taking only
  #   the basename threw the namespace away, which is exactly how a nested class ends
  #   up hunting for a generic word.
  #
  # `concerns/` IS DROPPED because Rails autoloads app/*/concerns as a root of its
  # own: app/models/concerns/position_concern.rb defines `PositionConcern`, not
  # `Concerns::PositionConcern`. Keeping the segment would name a constant that does
  # not exist, which is the same defect one directory deeper.
  #
  # A SCRIPT IS NAMED TWO WAYS AND BOTH ARE DELIBERATE, so a bin path yields two
  # spellings. Code that RUNS a script writes the path — `File.join(ROOT, "bin",
  # "session-kickoff")` — while the registries that ENUMERATE bin/ write the bare
  # command name as a quoted literal: test/lib/bin_help_flag_class_test.rb holds
  # `"register-satellite" => :optparse` for every script in the tree. Dropping the
  # quoted form cost five scripts their only mapped test (measured 2026-09-07:
  # bin/register-satellite, bin/reap-cert-databases, bin/island-background,
  # bin/docker-entrypoint, bin/devops-tests all fell to zero), and that one file is
  # a self-checking registry — the kind of test this whole family exists to reach.
  #
  # THE QUOTES ARE THE POINT, not a decoration. A quoted literal is a naming act;
  # a bare word is English. The same script name unquoted is what matched 325 files.
  # Worst case measured over this repo: `"release"` appears in 50 test files and
  # `"task"` in 37 — still an order of magnitude under the bare words they come from,
  # and in this repo neither reaches the grep at all (both have a harness family).
  #
  # RETURNS A LIST, and the list is the ONLY statement of the rule — #token_regexp
  # below turns each spelling into a pattern and #grep_tests unions them. Nothing
  # re-derives "which spellings does a bin path have"; a mutation to this case has
  # no second copy to hide behind.
  #
  # A CONFIG FILE IS NAMED TWO WAYS TOO — and shipping only one of them was the
  # ASYMMETRY this clause pair used to carry. A bin path got its path AND its quoted
  # command name; a config path got its path alone. So a test that named a config any
  # OTHER way stopped being selected when that config changed, and the loss is
  # concentrated in exactly the tests worth reaching: measured over this repo
  # 2026-09-07 at head 5bd97f64, FOUR of the 41 config sources lost a test that
  # genuinely names them, and two of those four are the config's OWN contract guard.
  #
  #   config/rails_lane.yml       lost test/lib/rails_lane_contract_test.rb, the file
  #                               that exists to assert that config's contract
  #   config/qa_environments.yml  lost test/lib/qa_registry_declares_qa_env_test.rb,
  #                               "THE PERMANENT GUARD over config/qa_environments.yml"
  #   config/initializers/edge_guard.rb  mapped to ZERO — losing BOTH edge-guard tests
  #   config/e2e_lane.yml         lost test/lib/review_tree_guard_test.rb
  #
  # THE SECOND SPELLING IS THE QUOTED BASENAME, WITH ITS EXTENSION, and the extension
  # is the whole reason this does not re-admit the English that rung 3 was fixed to
  # stop. Code that reaches a config by path writes it either whole —
  # `Rails.root.join("config/queue.yml")` — or SPLIT, which is the form the path token
  # cannot see: `File.join(ROOT, "config", "rails_lane.yml")` (rails_lane_contract_test.rb:33)
  # and `Rails.root.join("config", "qa_environments.yml")`. The basename with its
  # extension is a filename, never a word, so `"rails_lane.yml"` cannot match prose the
  # way `"jobs"` or `"rake"` still can on the bin side above. Measured: this spelling
  # adds THREE test paths across all 41 config sources, and each of the three is that
  # config's own guard.
  #
  # AND A CONFIG INITIALIZER IS NAMED BY THE CONSTANT IT WIRES — but only when that
  # constant is real. config/initializers/edge_guard.rb is the wiring half of a class
  # whose other half is lib/middleware/edge_guard.rb; both edge-guard tests name it
  # `EdgeGuard` and neither writes the initializer's path, so the initializer alone
  # mapped to nothing. See #wired_constant for why the constant is QUALIFIED by that
  # source existing rather than taken from the basename: unqualified, this same clause
  # hands config/environments/test.rb the token `Test` (208 files) and
  # config/initializers/studio.rb the token `Studio` (127) — the two widest cap trips in
  # the repo and precisely the defect PR #1254 closed. Widening this file has gone wrong
  # twice (PR #1239 over-matched; the bare-token grep was widening's endpoint), so the
  # qualification is the point, not a refinement.
  #
  # [] = no grep for this path (views/docs/assets rely on the spine).
  def grep_tokens(root, path)
    case path
    when %r{\Abin/([^/]+)\z} then [path, %("#{Regexp.last_match(1)}")]
    when %r{\Aconfig/.+\.(?:ya?ml|rb)\z} then [path, %("#{File.basename(path)}")] + wired_constant(root, path)
    when %r{\Aapp/(?:#{APP_LAYERS.join('|')})/(.+)\.rb\z} then [constant_path(Regexp.last_match(1))]
    when /\.rb\z/ then [camelize(File.basename(path, ".rb"))]
    else []
    end
  end

  # THE CONSTANT A CONFIG INITIALIZER WIRES — `[]` unless this repo actually defines it.
  #
  # WHY A QUALIFICATION AT ALL. The tempting rule is "camelize the basename", and it is
  # the rule the pre-#1254 grep used. It is also how config/environments/test.rb came to
  # hunt for `Test` and match 208 of the repo's 623 test files, and config/initializers/
  # studio.rb to hunt for `Studio` and match 127. Those two were the widest cap trips in
  # the repo. Re-adding the camelized basename unconditionally would hand both of them
  # straight back — a fix that trades one defect for the one just closed.
  #
  # WHAT SEPARATES `EdgeGuard` FROM `Test` AND `Studio` is not word count or spelling; it
  # is whether the constant EXISTS HERE. An initializer under config/ almost never defines
  # a class — it CONFIGURES one — so its constant is only a name when some source file in
  # this repo owns that name. lib/middleware/edge_guard.rb defines `EdgeGuard` (and the
  # initializer requires that very file). Nothing in this tree defines `Test`, `Studio`,
  # `Application`, `Routes`, `Queue` or `Storage`: those are English, Rails, a gem, or the
  # standard library, which is exactly why their matches were coincidence.
  #
  # MEASURED over every config source in this repo 2026-09-07 (head 5bd97f64): of the 24
  # `.rb` files under config/, exactly ONE qualifies — config/initializers/edge_guard.rb,
  # owned by lib/middleware/edge_guard.rb. The other 23 get no constant, including all
  # ten single-word names whose unqualified constant would have matched something.
  #
  # THE OWNERSHIP TEST ASKS #grep_tokens ITSELF rather than re-deriving "the constant a
  # source is named by". Stated twice, the two copies cover for each other and a mutation
  # to one survives — the failure PR #1239 hit, and the reason #harness_family states its
  # scope once. Asking grep_tokens also means the answer stays correct by construction if
  # the constant rules change. It cannot recurse: candidates come only from app/, lib/ and
  # bin/, never from config/, so the config clause is never re-entered.
  #
  # NOT APPLIED TO .yml, deliberately — a YAML file defines no constant, so borrowing
  # one from a same-named class would be inventing a name rather than reading it:
  # config/queue.yml is a file, not `Queue`, even in a repo that has a Queue class.
  #
  # THE GUARD IS LOAD-BEARING, and it took a mutation to find out it once was not. The
  # stem was cut with `File.basename(path, ".rb")`, which on a YAML path returns the
  # basename WITH its extension — so the lookup asked for `<something>.yml.rb`, matched
  # nothing, and returned [] whether or not the guard was there. Deleting the guard
  # changed no behaviour and no test went red: a redundant guard, green either way, and
  # green for a reason that lived in a different line. Cutting the stem with
  # File.extname makes the .yml path reach a real lookup, so the guard now decides
  # something and its test can kill it (see #test_a_yaml_config_never_borrows...).
  def wired_constant(root, path)
    return [] unless path.end_with?(".rb")

    stem = File.basename(path, File.extname(path))
    constant = camelize(stem)
    owners = Dir.glob("{app,lib,bin}/**/#{stem}.rb", base: root.to_s)
    owners.any? { |src| grep_tokens(root, src) == [constant] } ? [constant] : []
  end

  # A token matched at its own edges, where "edge" depends on what KIND of name the
  # token is. Two things this cannot be, both learned by being wrong:
  #
  #   NOT AN UNCONDITIONAL \b. It marks a word/non-word seam, so prefixing one to a
  #   token that STARTS with a quote would demand a word character before the quote
  #   and `"register-satellite"` would never match anything.
  #
  #   NOT \b FOR A PATH EITHER. `\bbin/task\b` MATCHES "bin/task-archive", because
  #   the hyphen is the non-word character \b is looking for. A path is extended by
  #   the very characters \b treats as boundaries, so a path token is bounded by the
  #   characters that can continue a path: `bin/task` must not match bin/task-archive
  #   or bin/task.rb, and `bin/release` must not match bin/release.rb.
  #
  # A CONSTANT keeps the word boundary, and must: `News::Review.new(news)` is the
  # canonical usage, so a trailing dot has to be a legal edge there.
  def token_regexp(token)
    t = token.to_s
    edge = t.include?("/") ? '[\w./-]' : '\w'
    body = Regexp.escape(t)
    body = "(?<!#{edge})#{body}" if t.match?(/\A\w/)
    body = "#{body}(?!#{edge})" if t.match?(/\w\z/)
    Regexp.new(body)
  end

  # "news/review" → "News::Review"; "concerns/position_concern" → "PositionConcern".
  def constant_path(rest)
    rest.sub(%r{\Aconcerns/}, "").split("/").map { |seg| camelize(seg) }.join("::")
  end

  def camelize(str)
    str.to_s.split(/[_\-]/).map { |part| part.sub(/\A[a-z]/) { |c| c.upcase } }.join
  end

  # Every test file under root whose text NAMES the subject — i.e. contains any one
  # of `tokens` at its own edges. Accepts a single token or a list of alternative
  # spellings (see #grep_tokens). Read-in-Ruby (not shell grep) for BSD/GNU
  # portability and determinism.
  def grep_tests(root, tokens)
    res = Array(tokens).map(&:to_s).reject { |t| t.strip.empty? }.map { |t| token_regexp(t) }
    return [] if res.empty?

    Dir.glob("test/**/*_test.rb", base: root.to_s).select do |rel|
      body = File.read(File.join(root, rel))
      res.any? { |re| body.match?(re) }
    rescue StandardError
      false
    end
  end

  # PER CHANGED FILE, what it maps to: its EXISTING convention targets, else its
  # harness FAMILY when the twin is missing, else the grep fallback.
  # Returns { changed_path => [test paths] }.
  #
  # THE THREE RUNGS ARE ORDERED BY HOW DIRECTLY THEY NAME THE SUBJECT — an existing
  # twin names it exactly, a family member names it by stem, a grep only mentions it.
  # #orphan_family sits between the two old rungs rather than beside the grep because
  # a family member IS the subject's test; falling past it to a word search was the
  # whole defect. The `else` branch is byte-identical to before, so every source with
  # an existing convention target maps exactly as it did.
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
          orphans = orphan_family(root, path)
          orphans.empty? ? grep_tests(root, grep_tokens(root, path)) : orphans
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
  # WHICH CAUSE ACTUALLY TRIPS THE CAP — swept over every mappable hub source, twice,
  # because the answer decides whether this fallback is a slope or just a shorter
  # cliff. Re-derived 2026-09-07 at head 3e678a19 over all 1928 sources (the earlier
  # sweep counted 474 by excluding test files, which map to themselves):
  #
  #   BEFORE the subject-reference fix: 27 sources ALONE exceed the cap. All 27 are
  #   GREP-driven. ZERO are family-driven. Widest: bin/task 325 ("task"),
  #   bin/release 257, config/environments/test.rb 208 ("Test"), bin/setup 198.
  #   AFTER: 9 do. Widest FAMILY mapping in the repo is still bin/dor-check at 15 —
  #   AT the cap, never over it alone; next widest family, 3.
  #
  #   RE-DERIVED 2026-09-08 over all 1952 tracked files, and the second half of that
  #   line has EXPIRED: 11 exceed the cap alone, and THREE of them never reach the
  #   grep — bin/release and bin/release.rb at 23 through the ORPHAN family, and
  #   bin/dor-check at 18 through its twin's family, having grown past the cap it once
  #   sat exactly on. These are counts of the TREE, not of the rule, so they move
  #   whenever test files are added; re-derive rather than paste.
  #
  # So the family hop trips the cap only IN COMBINATION with a co-changed file — the
  # cliff above — while every single-file cap trip WAS a grep precision failure. That
  # is what makes the fallback a slope rather than a shorter cliff, provably: the
  # grep-driven cap-trippers have ZERO convention twins, so the fallback takes nothing
  # from them and they degrade to the spine. Truncating 39 arbitrary grep matches to 15
  # arbitrary grep matches would be a shorter cliff; falling back to the TWIN is a slope.
  # THE "ZERO TWINS" HALF IS TRUE BY CONSTRUCTION, not merely in the measured cases:
  # #mapping looks past the convention target only when it is MISSING, so a source that
  # reaches the grep — or the orphan family — cannot have one. It is the argument that
  # survives every re-derivation of the counts above.
  #
  # THE PRECISION HALF IS NOW FIXED AT THE SOURCE (#grep_tokens, #orphan_family), which
  # does NOT retire this fallback and does not touch the cap. What survives the fix is
  # the more interesting half: the 9 sources still over the cap map to sets that are
  # PRECISE — every one of app/models/agent_activity.rb's 29 hits really does name
  # AgentActivity. Their counts are no longer an argument about selection; they are an
  # argument about the INSTRUMENT, since a cap that counts FILES cannot bound TIME
  # (measured: the 15-file bin/dor-check lane runs 220.0s against a ~60s budget, while
  # a 2-file twin fallback runs 97.7s). That question is deliberately left open here.
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
  # An initializer has no convention candidate, so it fell through to a grep — and
  # the token was the CAMELIZED BASENAME, so config/initializers/studio.rb hunted for
  # the word "Studio", which appears across the whole tree. A grep that matches half
  # the suite has told you nothing about which tests are RELEVANT; it has only told
  # you the token is too generic. Past the cap the honest move is to stop pretending
  # the mapping is a signal, run the spine, and say so loudly.
  #
  # THAT PARTICULAR TOKEN IS GONE: a config file is now named by its PATH, and
  # config/initializers/studio.rb maps to 3 files rather than 129 (2026-09-07). The
  # cap still stands, because precision is not a bound — see #grep_tokens for what
  # the grep asks now, and #convention_twins for what survives the fix.
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
    # WHAT THE FALLBACK WEIGHED, kept beside what it CHOSE, because the empty
    # fallbacks are different facts and a receipt that cannot tell them apart is a
    # shrug: N > cap means the twins were themselves too broad and the lane degraded a
    # second time, while 0 means there was nothing to weigh AT ALL. It is 0 when the cap
    # did NOT trip either — there was nothing to weigh then either — so read it only
    # beside :capped.
    #
    # AND 0 IS NOT ONE FACT, WHICH THIS KEY CANNOT SEE. `twins` arrives already
    # spine-deduped, so a diff whose only twin is a spine entry weighs 0 exactly like a
    # diff with no twin at all. THE CALLER SEPARATES THEM — it holds both sides of the
    # dedupe — via #empty_fallback_cause. Reading a bare 0 here as "no changed file has
    # a twin" is the false statement bin/fast-check printed to operators.
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

  # WHICH EMPTY A CAPPED RUN'S FALLBACK WAS — three answers, kept apart because two of
  # them were being told to the operator as one, and the one they were told as is a
  # claim about the DIFF that was not true.
  #
  #   :over_cap      the twins were themselves broader than the cap, so the lane
  #                  degraded a second time.
  #   :spine_covered twins EXIST for this diff and the SPINE already runs every one of
  #                  them. The lane has nothing to ADD — not the same statement as
  #                  having nothing to take.
  #   :none          no changed file has an existing convention twin.
  #
  # THE REACHABLE FALSE STATEMENT THIS CLOSES. `:fallback_considered` is counted AFTER
  # the spine dedupe (see #cap_decision), so a diff whose only twin is a spine entry
  # arrives with 0 considered — from that number alone, indistinguishable from a diff
  # with no twin at all. bin/fast-check printed "no changed file has an existing test
  # twin" for BOTH. Reproduced against this repo 2026-09-08:
  #
  #   FAST_CHECK_CHANGED_FILES=app/views/tasks/_board.html.erb,test/support/session_env.rb \
  #     bin/fast-check --print
  #   -> MAPPED LANE CAPPED — 79 mapped test file(s) exceeds the cap of 15.
  #        no changed file has an existing test twin, so there is no fallback to take.
  #
  # The view's twin is test/controllers/tasks_controller_test.rb, which IS a spine entry
  # and DID run. The OUTCOME was right — nothing to add that the spine is not already
  # running — and that is what makes the sentence the worse half: it sent the builder
  # hunting a coverage gap that does not exist, and a warning that fires on a false
  # negative is how builders learn to ignore warnings.
  #
  # PASSED THE DROPPED TWINS, NOT THE SPINE. This stays a pure decision over sets — the
  # caller already holds both sides of its own dedupe, and re-deriving "covered by the
  # spine" here would state that rule twice, which is how PR #1239's mutation survived.
  #
  # FAILS TO THE OLD SENTENCE: `spine_covered_twins:` defaults to [], so a caller that
  # has not been taught to pass it gets :none — the wording the fallback shipped with
  # (f0cc947a) — never a claim about a spine it never mentioned.
  #
  # :over_cap OUTRANKS :spine_covered. Both can hold at once, and the degradation is the
  # more useful fact: it says the lane HAD a fallback and gave it up for breadth.
  #
  # NOT MERGED WITH #fallback_note, deliberately. That note's identical wording is
  # CORRECT where it is used, because a deferral presupposes a spine that resolved to
  # nothing — so nothing can have been deduped away there, and :spine_covered cannot
  # arise. One sentence was wrong; the other was right for a reason. Fix one.
  def empty_fallback_cause(cap, spine_covered_twins: [])
    return :over_cap if cap[:fallback_considered].to_i > cap[:cap].to_i
    return :spine_covered if Array(spine_covered_twins).any?

    :none
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
  # `declared_spine` is what config/fast_cert_spine.yml ASKS FOR; `spine` is what this
  # CHECKOUT HAS. The gap between them is the satellite signal, and the two are passed in
  # separately precisely so this stays a pure decision over sets — see #declared_spine.
  #
  # BOTH NEW KWARGS FAIL CLOSED. `declared_spine:` defaults to [] (→ the old refusal) and
  # `remedy:` to the hub-relative command, so a caller that has not been taught about either
  # gets byte-identical behaviour. A loosening can only happen where someone WROTE one.
  def zero_test_outcome(mapped_only, spine, cap, slug: nil, declared_spine: [], remedy: nil)
    return nil unless executed_test_paths(mapped_only, spine, cap).empty?

    task = slug.to_s.strip.empty? ? "<task>" : slug.to_s.strip
    fix = default_remedy(task, remedy)
    return defer_outcome(cap, task, fix) if cap && cap[:capped]

    # Reaching here means `spine` is EMPTY — executed_test_paths is (mapped + spine) and it
    # just tested empty — so the only question left is whether a spine was ASKED FOR. If it
    # was, every declared entry failed to resolve, and that is a fact about the CHECKOUT.
    # Deliberately NOT re-asserting `spine.empty?`: a clause that cannot be false is a clause
    # no mutation can kill, and this file has been bitten by exactly that (PR #1239).
    return unresolved_spine_outcome(declared_spine, task, fix) if Array(declared_spine).any?

    { kind: :refuse, message: refuse_message(task, fix) }
  end

  # THE SATELLITE DEFERRAL — the second door into the deferral, and why it is a deferral
  # rather than a certification.
  #
  # MEASURED 2026-09-07 (re-derived; the 2026-09-06 figure held): the spine declares five
  # entries; the hub resolves 5/5 while turf-monster, rolio, turf-vault, studio-engine and
  # solana-studio each resolve 0/5. So one docs-only diff split two ways by WHERE THE BUILDER
  # STOOD — green in the hub, REFUSED on a satellite — while the refusal's own text blamed
  # the diff. That is the bug: a verdict decided by the checkout, reported as a fact about
  # the code.
  #
  # WHAT THE HUB'S GREEN ACTUALLY BUYS on such a diff is a TREE-HEALTH SMOKE TEST (the
  # task/release/gate models still pass), never coverage of the markdown that changed. A
  # satellite cannot run that smoke test; CI runs the satellite's WHOLE suite on this exact
  # tree. So deferring demands strictly MORE evidence than the hub's green for the same diff.
  # It is the capped case's argument with the same shape, which is why it lands in the same
  # machinery rather than a new one.
  #
  # AND IT CERTIFIES NOTHING, by construction. The caller exits DEFERRED_EXIT (2) — falsy to
  # every `system(...)` caller — records a fingerprint-bound "[cert-deferred@<fp>]" receipt,
  # and never reaches the lane runner or the "fast cert green" line. bin/dor-check credits
  # that receipt ONLY beside a GREEN CI. There is no path from here to a green cert.
  def unresolved_spine_outcome(declared, task, fix)
    count = Array(declared).size
    noun = count == 1 ? "entry" : "entries"
    detail = "cert DEFERRED to GitHub CI: this run would execute ZERO test files — the diff mapped to " \
             "no test file, and this checkout resolves NONE of the #{count} spine #{noun} declared in " \
             "config/fast_cert_spine.yml (the spine is anchored in the hub; a satellite checkout " \
             "resolves none of it). So no LOCAL lane could certify this tree — the CHECKOUT is why, " \
             "not the diff. CI runs the full suite on this exact code; bin/dor-check credits this " \
             "receipt only alongside a GREEN CI, never provisionally."
    message =
      "NOT CERTIFIED — DEFERRING to GitHub CI. #{detail}" \
      "\n  What happens next: bin/ship pushes and opens the PR anyway, waits for CI, and " \
      "bin/dor-check REFUSES the submit unless CI is GREEN. A red CI, no CI, or an edit after this " \
      "receipt all still block — deferring is not skipping." \
      "\n  Prefer to certify locally instead? #{fix}"
    { kind: :defer, message: message, detail: detail }
  end

  # The UNMAPPED refusal — the half that does not move. Kept verbatim from the guard PR
  # 1226 added, because the case it describes has not changed.
  def refuse_message(task, fix = nil)
    remedy_line = default_remedy(task, fix)
    "REFUSING TO CERTIFY — this run would execute ZERO test files, so there is nothing to " \
      "certify. the diff maps to NO test file — no convention target, and no word-boundary " \
      "grep hit — and NO spine is declared for this run to fall back on " \
      "(config/fast_cert_spine.yml is missing, empty, or unreadable). That leaves rubocop " \
      "as the only lane, and a linter cannot observe behaviour — a green cert here would be " \
      "a verdict on evidence that does not exist. Run the cert that DOES cover this diff:" \
      "\n    #{remedy_line}"
  end

  # The CAPPED deferral. `detail` is what goes on the recorded receipt — it must name the
  # cap, the count and the culprit, because a receipt nobody can read back to a cause is how
  # a deferral becomes a shrug. `message` is what the builder reads, and it says the two
  # things they need: nothing was certified here, and what has to be true later.
  def defer_outcome(cap, task, fix = nil)
    remedy_line = default_remedy(task, fix)
    # The deliberate-override line names the mapped lane by the SAME absolute
    # fast-check the reader just ran, so a satellite desk can paste it too.
    mapped_override = FastLane.remedy_command("fast-check", File.expand_path("..", __dir__), task)
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
      "\n  Prefer to certify locally instead? #{remedy_line}" \
      "\n  (or run the mapped lane anyway, deliberately: FAST_CHECK_MAPPED_CAP=#{cap[:count]} " \
      "#{mapped_override} — that is the broad local suite this cap exists to avoid.)"
    { kind: :defer, message: message, detail: detail }
  end

  # WHY THE TWINS FALLBACK DID NOT SAVE THIS RUN — the clause that keeps the deferral
  # receipt a complete explanation now that "capped" has a rung under it. Reaching a
  # deferral means the cap tripped AND the fallback came up empty, and the receipt has
  # to say which of the two empties it was or a reader cannot tell a diff that maps to
  # nothing from one whose twins were too broad.
  #
  # ONE CALLER, AND BOTH SENTENCES DEPEND ON IT: #defer_outcome, which is reached only
  # when NO test path will execute — so the spine resolved to nothing here, and the
  # receipt has already said so. Two consequences, and getting either backwards is how
  # this note stopped agreeing with the receipt that carries it:
  #
  #   THE THIRD RUNG IS NOT A DESTINATION HERE. "degraded a second time, to the spine"
  #   read as an offer of a rung the very same sentence has just called unresolvable.
  #   The degradation is real; where it lands is empty, and that is precisely WHY this
  #   run defers instead of certifying narrower.
  #
  #   THE `0 considered` WORDING IS CORRECT HERE, and is NOT the false statement
  #   bin/fast-check's narration carried. A deferral presupposes an empty spine, so
  #   nothing can have been deduped away and 0 really does mean no twin exists. The
  #   spine-covered case (#empty_fallback_cause) cannot arise where there is no spine.
  def fallback_note(cap)
    considered = cap[:fallback_considered].to_i
    if considered > cap[:cap].to_i
      "The convention-twin fallback did not save it either: #{considered} twin(s) is ITSELF over " \
        "the cap of #{cap[:cap]}, so the lane degraded a second time — to the spine, which this " \
        "checkout resolves none of, which is why this run ends here rather than in a narrower cert."
    else
      "The convention-twin fallback was empty too — no changed file has an existing test twin " \
        "(the fallback deliberately excludes the grep, which is what the cap is protecting you from)."
    end
  end

  # --- spine --------------------------------------------------------------------
  # The curated always-run core from config/fast_cert_spine.yml. Entries may be
  # files or directories; only ones that exist under root survive (the hub's
  # spine list silently no-ops in a satellite checkout).
  # WHAT THE CONFIG ASKS FOR, before any checkout is consulted. Split out from #spine
  # because the gap between the two — declared but unresolved — is the ONLY evidence that
  # distinguishes "this diff maps to nothing" from "this checkout is not the hub", and a
  # single read that filters as it goes cannot tell a caller which of the two it saw.
  # Fails CLOSED: a missing or unparseable config declares NOTHING, which routes to the
  # refusal rather than to the deferral.
  def declared_spine(config_path)
    data = YAML.safe_load(File.read(config_path.to_s)) || {}
    Array(data["spine"]).map(&:to_s)
  rescue Errno::ENOENT, Psych::SyntaxError
    []
  end

  def spine(root, config_path)
    declared_spine(config_path).select { |p| File.exist?(File.join(root, p)) }
  end

  # THE REMEDY — a command the READER'S repo can actually execute.
  #
  # MEASURED 2026-09-07: bin/full-suite-check exists ONLY in the hub. turf-monster, rolio,
  # turf-vault, studio-engine and solana-studio have no such file, so the bare
  # "bin/full-suite-check <task>" that both zero-evidence verdicts used to print was, verbatim,
  # a command the reader's checkout could not run. Naming a hub-only command at a satellite
  # builder is the same defect as a gate naming a workflow trigger that does not exist.
  #
  # THE FIX IS A PATH, AND DELIBERATELY NOTHING MORE. An earlier cut of this also tried to
  # detect repos with "no suite lane at all" and point them at a [full-suite-bypass] instead.
  # It was wrong twice over. The probe (no bin/rails, no gem-registry row) fired on turf-vault,
  # which HAS a ci.yml and real test commands (`yarn test:scripts`, an `anchor test` in
  # Anchor.toml) — measured 2026-09-07, after the probe was written. And the direction of its
  # error was the dangerous one: an over-fire tells a builder with a real suite to RECORD A
  # SKIP. So no such branch exists. The hub's bin/full-suite-check is always named, and when it
  # genuinely cannot resolve a command for a checkout it refuses on its own terms, loudly,
  # naming what it could not read (bin/lib/ci_test_command.rb) — a recoverable under-fire
  # instead of an invitation to skip the evidence.
  # BOTH ARMS ARE NOW ABSOLUTE, and the hub arm's bare form is gone. It was defensible
  # on its own — CertRootGuard makes the cert writers' cwd agree with `root`, so a hub
  # tree DOES carry a runnable bin/full-suite-check — but it rested on a guard the
  # FAST_CHECK_ROOT seam bypasses, and it left one refusal speaking two dialects: every
  # OTHER command in the same fast-check output is now absolute. Partial correction is
  # how this house ends up with two authorities on one question, and the arm a guard
  # exercises should be the arm every builder is handed.
  #
  # RESOLVED BY EXISTENCE, NOT BY REPO IDENTITY. The old `root == hub_root` comparison
  # asked "is this the hub?"; this asks the only question that decides whether the
  # command runs — "is there an executable there?" — preferring the tree being certified
  # and falling back to the hub. That self-heals: onboard a repo, or give a satellite a
  # bin/full-suite-check shim, and the remedy follows the disk instead of a registry
  # somebody has to remember. When neither exists the hub path is still named, so the
  # reader gets an absolute path to reason about rather than a bare word that hides the
  # question. See FastLane.remedy_command.
  def remedy(task, root:, hub_root:)
    FastLane.remedy_command("full-suite-check",
                            [File.join(root.to_s, "bin"), File.join(hub_root.to_s, "bin")],
                            task)
  end

  # The remedy a caller that passed none gets — the hub's own full suite, absolute,
  # resolved from THIS file's own bin dir (bin/lib → bin). It is a fallback, not the
  # normal path: bin/fast-check always passes an explicit `remedy:`.
  def default_remedy(task, fix = nil)
    given = fix.to_s.strip
    return given unless given.empty?

    FastLane.remedy_command("full-suite-check", File.expand_path("..", __dir__), task)
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

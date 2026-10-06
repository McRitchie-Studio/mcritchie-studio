# frozen_string_literal: true

# `bin/release prepare`'s gem lane: publish, consumer lock bumps, bundle lock retries,
# self-gated gem-only candidates and the fail-closed gem checks.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_prepare_gems_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliPrepareGemsTest < ReleaseCliHarness
  def test_prepare_dry_run_gem_member_rides_the_release
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    assert_includes out, "rides the release",
                    "a gem member is published before QA + verified at ship — never QA-deployed itself"
  end

  # [integration] The ordering that IS the feature: gem publish → consumer lock
  # bump commit → pre-QA gate → QA deploy. The lock commit landing BEFORE the gate
  # is what points the CI verdict at the post-bump release SHA.
  def test_prepare_publishes_gems_and_bumps_locks_before_the_pre_qa_gate_and_qa_deploy
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub)

    publish = out.index("GEM-PUSH")
    bump    = out.index("LOCK-PUSH")
    gate    = out.index("pre-QA gate mcritchie-studio")
    deploy  = out.index("QA-DEPLOY")
    assert publish && bump && gate && deploy,
           "publish, lock-bump, gate, and QA deploy must ALL appear: #{out}"
    assert_operator publish, :<, bump,   "gems publish before any consumer lock bump (producer-first)"
    assert_operator bump, :<, gate,      "the lock bump commits BEFORE the pre-QA gate reads origin/release"
    assert_operator gate, :<, deploy,    "the gate still precedes the QA deploy"
    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0",
                    "a single-gem bump uses conservative lock semantics"
    assert_includes out, "committed studio-engine 1.0.0",
                    "the bump commit narrates what landed on origin/release"
  end

  # [integration] The constraint-escape rule: `~> 0.10` HOLDS a minor bump
  # (lock-only — the Gemfile pin is untouched) and is REWRITTEN by a major bump
  # that escapes it.
  def test_prepare_rewrites_the_consumer_pin_only_when_the_published_version_escapes_it
    escaped = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0"))
    assert_includes escaped, %(GEMFILE-AFTER gem "studio-engine", "~> 1.0"),
                    "a major bump escapes `~> 0.10` — the pin advances with the lock"

    held = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "0.11.0"))
    assert_includes held, %(GEMFILE-AFTER gem "studio-engine", "~> 0.10"),
                    "a minor bump is WITHIN `~> 0.10` — lock-only, the pin stays"
    assert_includes held, "BUNDLE-LOCK studio-engine conservative=true expect=0.11.0"
  end

  # [integration] The STRANDED-WORK guard: origin/release ahead of the last
  # published tag with an UNBUMPED version_file must BLOCK loudly BEFORE anything
  # publishes or deploys — the silent publish-skip that stranded engine commits.
  #
  # THE GUARD IS NOW A BACKSTOP, and this drives it as one. Step 4d's phase 0
  # allocates the version, so on the happy path prepare fixes this state before
  # the guard ever sees it — which is exactly why the guard must keep firing when
  # allocation does NOT happen (skipped, refused, or wrong). `allocate: false`
  # models that, and the guard has to behave precisely as it always did.
  def test_prepare_blocks_loudly_on_stranded_gem_work_when_allocation_did_not_run
    out = run_cli(["--yes"], setup: gem_publish_stub(version: "0.10.0", allocate: false),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "stranded gem work must abort prepare, never silently skip"
    assert_includes out, "abc123 stranded engine commit", "the abort NAMES the stranded commits"
    assert_includes out, "STRANDING"
    assert_includes out, "Bump the version in studio-engine/", "the abort hands over the exact fix"
    assert_includes out, "re-run `bin/release prepare`"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes past the guard"
    refute_includes out, "LOCK-PUSH", "no lock bump past the guard"
    refute_includes out, "QA-DEPLOY", "no QA deploy past the guard"
  end

  # [integration] THE PROPAGATION-LAG GUARD (rel-20260809-3b8f3d, 2026-08-09).
  #
  # `bundle lock --update` exits 0 whether or not it could SEE the version we
  # published seconds earlier. When the RubyGems index has not propagated it
  # resolves the OLD version and leaves the tree unchanged — which is byte-for-byte
  # what a genuine already-bumped re-run looks like. prepare used to read that
  # unchanged tree and announce "lock already at studio-engine 1.0.0", a version it
  # had never read. turf-monster rode QA on the old engine while the release record
  # asserted the new one, and the pre-QA gate CREDITED its identical-tree green, so
  # no CI run contradicted it either.
  #
  # [integration] THE CALLER'S HALF of the guarantee: prepare hands every touched
  # gem's PUBLISHED version to bundle_lock as `expect:`, so the read-back+ladder
  # can run at all. Without this wiring the guard is inert no matter how correct
  # bundle_lock is.
  #
  # (The abort itself is NOT asserted here on purpose. This harness stubs
  # bundle_lock wholesale, so an abort in this test would come from the stub, not
  # the code — it would assert the double. The real refusal and its retry ladder
  # are driven against the live implementation in
  # test_bundle_lock_retries_a_stale_resolution_then_aborts_naming_the_compact_index.)
  def test_prepare_passes_the_published_version_to_bundle_lock_as_expect
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: ["1.0.0"], lock_dirty: false, tag: "v1.0.0", ahead: ""))

    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0",
                    "prepare must tell bundle_lock which version has to land: #{out}"

    # The old wording was the lie itself — a version claimed but never read. It
    # must not survive anywhere, even on the genuine no-op path.
    refute_includes out, "lock already at",
                     "prepare must never claim a version it has not read out of the lockfile"
    assert_includes out, "lock verified at studio-engine 1.0.0",
                    "the no-op message is now EARNED — bundle_lock proved the version before returning"
  end

  # [integration] THE LADDER, driven for real. The stub above replaces
  # bundle_lock wholesale, so it proves the CALLER refuses a stale lock but says
  # nothing about the retry. Here `sh` is stubbed instead: `bundle lock` "succeeds"
  # every time while the lockfile stays stale, so the REAL bundle_lock runs its
  # propagation ladder — retry, retry, then abort.
  #
  # This is review finding (1): the ladder already existed but only ever retried a
  # NON-ZERO exit, and this bug's signature is exit 0 with the old version still
  # resolved. Aborting on first observation would turn an ordinary, self-curing
  # index delay into a manual stop moments after an IRREVERSIBLE gem push.
  def test_bundle_lock_retries_a_stale_resolution_then_aborts_naming_the_compact_index
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            studio-engine (0.10.0)
      LOCK

      setup = %(ENV["RELEASE_BUNDLE_LOCK_BACKOFF"] = "0"\n) + <<~'RUBY'
        # `bundle` always succeeds; the lockfile never changes — the propagation case.
        def sh(*a, **k)
          $stdout.puts("BUNDLE-RAN") if a[0] == "bundle"
          ["", true]
        end
      RUBY

      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; bundle_lock(#{dir.inspect}, "studio-engine", expect: "1.0.0"); } +
                          %{puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_equal 3, out.scan("BUNDLE-RAN").size,
                   "the stale resolution must ride the SAME 3-attempt ladder a non-zero exit does: #{out}"
      assert_includes out, "resolves 0.10.0, wanted 1.0.0",
                      "each retry names what it actually saw"
      assert_includes out, "ABORTED", "and it aborts once the ladder is exhausted"
      refute_includes out, "NO-ABORT"

      # Point at the surface BUNDLER reads. What failed is `bundle lock`, and
      # bundler resolves through the COMPACT INDEX. The versions JSON API (what
      # rubygems_versions reads, for publish idempotency only) and the HTML gem
      # page are separate services with their own CDN caching, so a version
      # visible on either is not proof bundler can resolve it — and an operator
      # who waits on one re-enters the publish branch, gets `gem push` refused as
      # already-live, and is then advised to bump — burning a number for nothing.
      assert_includes out, "https://index.rubygems.org/info/studio-engine",
                      "the abort names the compact index bundler resolves through"
      refute_includes out, "https://rubygems.org/api/v1/versions/studio-engine.json",
                       "never send the operator to the versions JSON API — bundler does not read it"
      refute_includes out, "https://rubygems.org/gems/studio-engine",
                       "never send the operator to the HTML gem page either"
    end
  end

  # [integration] A lock that DOES land mid-ladder stops retrying and returns.
  def test_bundle_lock_stops_as_soon_as_the_version_lands
    Dir.mktmpdir do |dir|
      lock = File.join(dir, "Gemfile.lock")
      File.write(lock, "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (0.10.0)\n")

      setup = %(ENV["RELEASE_BUNDLE_LOCK_BACKOFF"] = "0"\n) +
              %(LOCKFILE = #{lock.inspect}\n) + <<~'RUBY'
                # Propagation arrives on the SECOND attempt.
                $attempt = 0
                def sh(*a, **k)
                  if a[0] == "bundle"
                    $attempt += 1
                    $stdout.puts("BUNDLE-RAN #{$attempt}")
                    if $attempt >= 2
                      File.write(LOCKFILE, File.read(LOCKFILE).sub("(0.10.0)", "(1.0.0)"))
                    end
                  end
                  ["", true]
                end
              RUBY

      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; bundle_lock(#{dir.inspect}, "studio-engine", expect: "1.0.0"); } +
                          %{puts("LANDED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "LANDED", "a version that arrives mid-ladder must succeed: #{out}"
      assert_equal 2, out.scan(/BUNDLE-RAN \d/).size, "and stop retrying the moment it lands"
      refute_includes out, "ABORTED"
    end
  end

  # [integration] The self-healing re-run: version already live + lock already
  # bumped → publish and commit both skip, and the QA half still runs.
  def test_prepare_gem_publish_and_lock_bump_are_idempotent_on_a_re_run
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: [{ "number" => "1.0.0" }], lock_dirty: false, tag: "v1.0.0", ahead: ""))

    assert_includes out, "already live on RubyGems — skip publish", "an already-published version skips"
    assert_includes out, "nothing to commit (idempotent re-run)", "an already-bumped lock commits nothing"
    refute_includes out, "GEM-BUILD"
    refute_includes out, "GEM-PUSH"
    refute_includes out, "LOCK-PUSH"
    assert_includes out, "QA-DEPLOY", "the re-run still deploys QA (self-healing resumes the deploy half)"
  end

  def test_prepare_dry_run_previews_the_gem_publish_and_lock_bump_without_executing
    out = run_cli(["--dry-run"], call: "prepare", setup: gem_publish_stub)

    assert_includes out, "stranded-work guard", "the dry run previews the guard"
    assert_includes out, "bump consumer locks", "the dry run previews the consumer bump"
    assert_includes out, "idempotent; no-op when already current"
    refute_includes out, "GEM-BUILD", "a dry run builds nothing"
    refute_includes out, "GEM-PUSH", "a dry run publishes nothing"
    refute_includes out, "BUNDLE-LOCK", "a dry run locks nothing"
    refute_includes out, "LOCK-PUSH", "a dry run pushes nothing"
  end
  # [integration] THE irreversible-ordering regression: gem 1 (studio-engine
  # 1.0.0) is healthy and would publish; gem 2 (solana-studio 0.10.0 == its last
  # tag, one commit ahead) fails the stranded-work guard. Interleaved code pushes
  # gem 1 BEFORE gem 2 aborts; the two-phase preflight must abort with ZERO
  # pushes — nothing builds, nothing publishes, nothing bumps, nothing deploys.
  def test_prepare_second_gem_validation_failure_publishes_zero_gems
    out = run_cli(["--yes"], setup: gem_publish_stub + TWO_GEM_SECOND_STRANDED,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a late validation failure must abort the whole publish step"
    assert_includes out, "solana-studio", "the abort names the failing gem"
    assert_includes out, "NOTHING was published", "the abort states the zero-publish guarantee"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-BUILD", "the healthy FIRST gem must not even build before the preflight settles"
    refute_includes out, "GEM-PUSH", "ZERO gems publish when ANY swept gem fails validation"
    refute_includes out, "LOCK-PUSH", "no consumer lock bump past a failed preflight"
    refute_includes out, "QA-DEPLOY", "no QA deploy past a failed preflight"
  end
  # [integration] FAIL CLOSED on a failed fetch: a transient fetch failure must
  # never let a stale origin/release drive an irreversible publish (or silently
  # skip a new gem, then gate + QA the old lock). Named abort, zero pushes.
  def test_prepare_gem_fetch_failure_fails_closed_before_any_publish
    out = run_cli(["--yes"], setup: gem_publish_stub + GEM_FETCH_FAIL,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a failed gem fetch must abort, not proceed on a stale ref"
    assert_includes out, "git fetch failed in gem studio-engine", "the abort names the repo and the failed fetch"
    assert_includes out, "fail closed", "the abort states the discipline"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes from a possibly-stale origin/release"
    refute_includes out, "LOCK-PUSH", "no lock bump on a failed preflight"
  end
  # [integration] The SELF-GATED gem-only candidate IS ALLOWED (gem-only-deployments):
  # a gem whose registry `release_check` is its own release-candidate verdict may be
  # its OWN release — it publishes, gets a first-class G3 verdict on its OWN suite's
  # CI (the self-gated-gem pass, resolved through the same tree-identical credit the
  # apps use), and assembles QA-green with NO app QA deploy. This is the whole point
  # of the change: a gem-only publish flows through the tracker instead of being
  # hard-refused.
  def test_prepare_self_gated_gem_only_candidate_is_allowed_and_gated_on_its_own_ci
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub + GEM_ONLY_CONDUCTOR)

    refute_includes out, "ABORTED", "a self-gated gem-only candidate must NOT be refused"
    assert_includes out, "GEM-PUSH", "a self-gated gem-only candidate publishes"
    assert_includes out, "pre-QA gate studio-engine (self-gated gem): GitHub CI GREEN",
                    "the self-gated gem earns its own G3 verdict on its own suite's CI"
    assert_includes out, "Assembled rel-gemonly", "the gem-only release assembles QA-green"
    refute_includes out, "QA-DEPLOY", "a gem-only release has NO app QA deploy"
  end

  # [integration] The gem-only bypass still bites for a NON-self-gated gem: with no
  # app member AND no `release_check` to gate itself, the candidate would publish and
  # assemble QA-green with nothing ever exercising the gem. Preflight must abort it
  # BEFORE the irreversible publish, naming BOTH the missing app and the
  # not-self-gated reason, plus the enroll-a-consumer fix.
  def test_prepare_non_self_gated_gem_only_candidate_aborts_before_any_publish
    out = run_cli(["--yes"], setup: gem_publish_stub + SOLANA_GEM_ONLY_CONDUCTOR + ReleaseCliStubs::NOT_SELF_GATED,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a NON-self-gated gem-only candidate must not publish + assemble unQA'd"
    assert_includes out, "NO app member", "the abort names the gem-only condition"
    assert_includes out, "not self-gated", "the abort names WHY solana-studio can't release alone"
    assert_includes out, "solana-studio", "the abort names the offending gem"
    assert_includes out, "enroll the consuming app", "the abort hands over the fix"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes on a non-self-gated gem-only candidate"
    refute_includes out, "QA-DEPLOY"
  end

  # [integration] THE PRODUCTION-DOWNGRADE vector, end to end (round-5 blocker).
  # version_file declares 0.9.0 while the last published tag is v0.10.0 — the
  # route in is a version.rb conflict resolved the wrong way on a merge into
  # release. Before the ordering fix this walked the ENTIRE pipeline green:
  # guard passed, publish "skipped" as already-live, and the consumer pin was
  # rewritten DOWNWARD to `~> 0.9` and committed to origin/release. Now it must
  # abort in phase 1: zero publishes, and — the assertion that matters most —
  # NO downward pin rewrite ever reaches a commit.
  #
  # Driven with allocation OFF (`allocate: false`) for the same reason as the
  # stranded test above: phase 0 now allocates forward over this backward version
  # (0.10.1 for these inputs — the last tag v0.10.0 plus the patch an untyped
  # member earns) before phase 1 reads it, so the DOWNGRADE branch is reachable
  # only when allocation did not run. It must still fail closed there.
  def test_prepare_backward_gem_version_aborts_and_never_downgrades_a_consumer
    out = run_cli(["--yes"], setup: gem_publish_stub(version: "0.9.0", live: [{ "number" => "0.9.0" }],
                                                    allocate: false),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a backward version must BLOCK, never publish or skip"
    assert_includes out, "DOWNGRADE", "the abort names the downgrade it prevented"
    assert_includes out, "past the last published tag v0.10.0", "the abort names the REAL tag"
    refute_includes out, "NO-ABORT"
    refute_includes out, "already live on RubyGems — skip publish",
                    "the misleading idempotent-skip line must NOT appear for a backward version"
    refute_includes out, "GEM-PUSH", "zero gems publish on a backward version"
    refute_includes out, %(GEMFILE-AFTER gem "studio-engine", "~> 0.9"),
                    "the consumer pin must NEVER be rewritten downward"
    refute_includes out, "LOCK-PUSH", "no downgrade commit reaches origin/release"
    refute_includes out, "QA-DEPLOY"
  end
  # [integration] The no-consumer guard still bites for a NON-self-gated gem: a gem
  # NO swept consumer bundles AND with no `release_check` to gate itself would still
  # assemble QA-green untested. Preflight must catch the missing coverage before the
  # publish. (ReleaseCliStubs makes the gem non-self-gated, so the check applies.)
  def test_prepare_non_self_gated_gem_with_no_swept_consumer_aborts_before_any_publish
    out = run_cli(["--yes"], setup: gem_publish_stub + SOLANA_MIXED_CONDUCTOR + ReleaseCliStubs::NOT_SELF_GATED,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a non-self-gated gem with no swept consumer must not publish"
    assert_includes out, "no consuming app in this sweep", "the abort names the missing coverage"
    assert_includes out, "solana-studio", "the abort names the offending gem"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes without a consumer to QA it through"
    refute_includes out, "LOCK-PUSH"
  end

  # [integration] The relaxation's companion: a SELF-GATED gem (studio-engine)
  # riding an app whose Gemfile does NOT declare it is ALLOWED to publish — a
  # self-gated gem does not need a consumer to be QA'd (its own suite is its
  # verdict), so the per-gem no-consumer guard is correctly skipped for it.
  def test_prepare_self_gated_gem_with_no_swept_consumer_still_publishes
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub + EMPTY_CONSUMER_GEMFILE)

    refute_includes out, "ABORTED", "a self-gated gem needs no consumer — it must not be refused"
    refute_includes out, "no consuming app in this sweep", "the no-consumer guard is skipped for a self-gated gem"
    assert_includes out, "GEM-PUSH", "the self-gated gem publishes even with no consumer bundling it"
  end
end

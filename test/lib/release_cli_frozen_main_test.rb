# frozen_string_literal: true

# The ship's push to main: commit_artifact_to_accepted, push_frozen_main, the printed
# reconcile, and the push-failure classifier.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_frozen_main_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliFrozenMainTest < ReleaseCliHarness
  # [unit] While another invocation holds the checkout (the gate's suite run),
  # the artifact dance must SKIP — best-effort, non-fatal, HEAD untouched — not
  # queue behind a ~6-min suite and never flip main↔accepted under it. The test
  # process holds the flock exactly as the gate does.
  def test_commit_artifact_to_accepted_skips_without_flipping_while_the_checkout_is_locked
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      doc = File.join(clone, "retro.md")
      File.write(doc, "retro fixture") # the SOLE uncommitted change → safe_to_commit? passes

      lock = File.open(File.join(dir, "mcr-primary-checkout-sibling.lock"), File::CREAT | File::RDWR, 0o644)
      assert lock.flock(File::LOCK_EX | File::LOCK_NB), "test setup: the lock must start free"

      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{commit_artifact_to_accepted("sibling", #{doc.inspect}, "retro: fixture"); puts("DONE")})

      assert_includes out, "left retro.md uncommitted", "the dance must skip while the checkout is locked"
      assert_includes out, "primary checkout busy", "…naming the concurrent holder as the reason"
      refute_includes out, "committed retro.md", "…never committing mid-gate"
      assert_includes out, "DONE", "the skip stays NON-FATAL (archive/retro ride on)"
      head, = Open3.capture2("git", "-C", clone, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal "main", head.strip, "HEAD must never leave main while the lock is held elsewhere"
      count, = Open3.capture2("git", "-C", clone, "rev-list", "--count", "--all")
      assert_equal "1", count.strip, "no commit lands on any branch while the checkout is locked"
    ensure
      lock&.close
    end
  end

  # [unit] Uncontended, the dance still works end-to-end: takes the lock,
  # commits the doc onto accepted, pushes, restores main, releases the lock.
  def test_commit_artifact_to_accepted_commits_and_restores_main_when_uncontended
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      run_git(clone, "push", "-q", "origin", "main:accepted")
      doc = File.join(clone, "retro.md")
      File.write(doc, "retro fixture")

      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{commit_artifact_to_accepted("sibling", #{doc.inspect}, "retro: fixture"); puts("DONE")})

      assert_includes out, "committed retro.md to accepted", "a free checkout commits the artifact"
      assert_includes out, "DONE"
      head, = Open3.capture2("git", "-C", clone, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal "main", head.strip, "HEAD stays on main (the commit is built from origin)"
      count, = Open3.capture2("git", "-C", clone, "rev-list", "--count", "origin/accepted")
      assert_equal "2", count.strip, "the artifact commit is pushed onto origin/accepted, never origin/release"
      File.open(File.join(dir, "mcr-primary-checkout-sibling.lock"), File::RDWR | File::CREAT, 0o644) do |f|
        assert f.flock(File::LOCK_EX | File::LOCK_NB), "the dance must RELEASE the lock afterwards"
      end
    end
  end

  # --- the ship's own checkout: main advances by REF PUSH, not by ff -----------
  #
  # HISTORY (2026-07-12). ship used to advance `main` by flipping the SHARED PRIMARY
  # (checkout main → pull → merge --ff-only → push), so it had to REFUSE a dirty
  # primary — and that refusal aborted a real production ship, after the gems had
  # published, because a concurrent feature session had staged work there. Advancing
  # a remote branch never needed a working tree: `git push origin
  # <frozen>:refs/heads/main` reads the shared object store, moves no HEAD, touches
  # no index, and is still fast-forward-checked by git. These are the proofs, on a
  # REAL git fixture, that the deploy is now indifferent to the primary's state.

  # [integration] The core acceptance: origin/main reaches the frozen SHA while the
  # primary is DIRTY and sitting on a feature branch — and comes out of it dirty, on
  # that same branch, with the stranded work untouched. Nothing is stashed, nothing
  # is discarded, nothing is checked out.
  def test_push_frozen_main_advances_origin_from_a_dirty_off_main_primary
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      frozen = git_out(clone, "rev-parse", "release")

      # A live feature session's floor: a branch, a staged file, an untracked file.
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")
      run_git(clone, "add", "app.rb")
      File.write(File.join(clone, "notes.txt"), "scratch")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "a dirty primary must NOT abort the ship: #{out}"
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "origin/main must reach the frozen SHA — that is what prod deploys"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary must still be on the session's branch — the ship never checked it out"
      status = git_out(clone, "status", "--porcelain")
      assert_includes status, "app.rb",   "the session's staged work must survive untouched"
      assert_includes status, "notes.txt", "…and its untracked file too"
    end
  end

  # [integration] FAILS CLOSED. If origin/main has diverged from the frozen SHA, git
  # refuses the non-fast-forward ref update and the ship ABORTS — it must never
  # --force a rewind onto production.
  def test_push_frozen_main_aborts_on_a_diverged_origin_main_and_never_forces
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # origin/main moves somewhere our frozen SHA cannot fast-forward to.
      run_git(clone, "checkout", "-q", "-b", "rogue", base)
      File.write(File.join(clone, "rogue.txt"), "pushed straight to main")
      run_git(clone, "add", "rogue.txt")
      run_git(clone, "commit", "-q", "-m", "rogue")
      run_git(clone, "push", "-q", "origin", "rogue:main")
      diverged = git_out(origin, "rev-parse", "main")
      frozen   = git_out(clone, "rev-parse", "release")

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a diverged origin/main must abort, not force: #{out}"
      assert_includes out, "NOT forcing", "the abort must say it refused to force"
      assert_equal diverged, git_out(origin, "rev-parse", "main"),
                   "production's main must be left EXACTLY as it was — never rewound"
    end
  end

  # THE WIRING, which the pure classifier tests at the end of this file cannot
  # see. push_frozen_main used to call `sh` WITHOUT capture and then assert a cause
  # it had thrown away the evidence for; a classifier that is never handed git's
  # output is a classifier that always answers the same thing. `sh` is stubbed to
  # refuse the push exactly the way the real one did on 2026-08-29.
  def test_push_frozen_main_reads_the_auth_failure_instead_of_asserting_a_divergence
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      setup = <<~RUBY
        def repo_path(_repo) = #{clone.inspect}
        # HONOURS `capture:`, exactly as the real sh does — returning git's output
        # only when the caller asked for it. A stub that hands back the output
        # either way is MORE GENEROUS THAN REALITY, and it certifies the one thing
        # this test exists to check: dropping `capture: true` at the call site
        # would leave the classifier reading "" and this case would still pass.
        # Measured — that mutation survived until this stub was tightened.
        def sh(*cmd, capture: false, chdir: nil, env: nil)
          if cmd.include?("push")
            return ["", false] unless capture

            return [<<~GIT, false]
              remote: Invalid username or token. Password authentication is not supported for Git operations.
              fatal: Authentication failed for 'https://github.com/McRitchie-Studio/sibling/'
              error: failed to push some refs to 'https://github.com/McRitchie-Studio/sibling'
            GIT
          end

          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", "a" * 40); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a refused push still aborts the ship"
      assert_includes out, "REFUSED ON CREDENTIALS",
                      "git said `Invalid username or token`; the ship must repeat that, not invent a divergence"
      # REBOUND like its sibling above — the flag it pinned belonged to a removed
      # remedy; the concern (an AUTH failure names its own lane) is asserted here.
      assert_includes out, "DEPLOYER identity", "and name the lane whose credential it actually is"
      refute_includes out, "has diverged from the frozen SHA",
                      "NOTHING had diverged — main was strictly BEHIND release and a dry-run fast-forward " \
                      "succeeded. This sentence, on this failure, cost a re-freeze that was never needed."
      assert_includes out, "Invalid username or token",
                      "git's own words must still reach the operator — the diagnosis explains the output, " \
                      "it does not replace it"
    end
  end

  # --- the deployer token is minted before every push --------------------------

  # A broker script standing in for bin/gh-token: it logs its argv and runs `body`.
  def push_broker(dir, body)
    File.join(dir, "broker").tap do |path|
      File.write(path, "#!/bin/sh\necho \"$@\" >> #{File.join(dir, 'mints')}\n#{body}\n")
      File.chmod(0o755, path)
    end
  end

  # `sh` that records each push with the GH_TOKEN it was handed, and succeeds.
  def push_recorder(dir, broker)
    <<~RUBY
      ENV["GH_AUTH_TOKEN_BIN"] = #{broker.inspect}
      ENV["GH_TOKEN"] = "aged-ambient-token"
      ENV.delete("GH_APP_ITEM")
      def repo_path(_repo) = #{dir.inspect}
      def advance_accepted(*) = nil
      def sleep(seconds) = puts("SLEEP \#{seconds}")
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        puts("PUSH mints_so_far=\#{File.readlines(#{File.join(dir, 'mints').inspect}).size} " \\
             "token=\#{(env || {})['GH_TOKEN'].inspect}") if cmd.include?("push")
        ["", true]
      end
    RUBY
  end

  PUSH_CALL = %{begin; %s; puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end}

  # [unit] One mint per push, as the deployer whatever GH_APP_ITEM says, before the push.
  def test_push_premints_deployer
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, "echo fresh-token")
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_includes out, "PASSED", out
      assert_equal ["--identity deployer --force"], File.readlines(File.join(dir, "mints"), chomp: true),
                   "exactly one mint, naming the deployer"
      assert_includes out, %(PUSH mints_so_far=1 token="fresh-token"), "the mint precedes the push and rides it"
      refute_includes out, "SLEEP", "a first-try mint does not wait"
    end
  end

  # [unit] An aged launch token: every push carries its own fresh mint, never the ambient one.
  def test_an_aged_ambient_token_never_rides_a_push
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, %(echo "fresh-$(wc -l < #{File.join(dir, 'mints')} | tr -d ' ')"))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{%w[hub turf].each { |r| push_frozen_main(r, "a" * 40) }}))

      assert_includes out, %(PUSH mints_so_far=1 token="fresh-1")
      assert_includes out, %(PUSH mints_so_far=2 token="fresh-2"), "the second push re-mints: #{out}"
      refute_includes out, %(token="aged-ambient-token")
    end
  end

  # [unit] A mint that fails once is retried after five seconds, and the push proceeds.
  def test_a_failed_mint_retries_once_then_pushes
    Dir.mktmpdir do |dir|
      mints = File.join(dir, "mints")
      broker = push_broker(dir, %(if [ "$(wc -l < #{mints} | tr -d ' ')" = "1" ]; then echo "op: timeout" >&2; exit 1; fi\necho fresh-token))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_equal 1, out.scan("SLEEP 5").size, "one wait of five seconds: #{out}"
      assert_includes out, %(PUSH mints_so_far=2 token="fresh-token")
      assert_includes out, "PASSED"
    end
  end

  # [unit] Two failed mints abort before the push; a DNS cause is named as the network.
  def test_a_mint_failing_twice_on_dns_aborts_naming_the_network
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, %(echo "gh-token: getaddrinfo: nodename nor servname provided, or not known" >&2; exit 1))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_includes out, "ABORTED", out
      assert_equal 2, File.readlines(File.join(dir, "mints")).size, "one mint and one retry, no more"
      assert_equal 1, out.scan("SLEEP 5").size
      refute_includes out, "PUSH ", "the push is not attempted without a token"
      assert_includes out, "deployer mint said: gh-token: getaddrinfo", "the mint's own words reach the log"
      assert_includes out, "NETWORK failure"
      refute_includes out, "REFUSED ON CREDENTIALS"
    end
  end

  # The control: a mint that fails for another reason is not called a network failure.
  def test_a_mint_failing_twice_for_another_reason_names_the_mint
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, %(echo "gh-token: 1Password read failed for item github.mcritchie-admin" >&2; exit 1))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_includes out, "ABORTED", out
      assert_includes out, "could not mint the DEPLOYER token"
      assert_includes out, "deployer mint said: gh-token: 1Password read failed"
      refute_includes out, "NETWORK failure"
      refute_includes out, "PUSH "
    end
  end

  # --- post-ship: re-baseline origin/accepted onto the shipped SHA -------------
  #
  # DevOps v2 Phase 3, Slice 1. After push_frozen_main advances `main`, it also
  # fast-forwards this repo's persistent `accepted` integration branch onto the
  # same frozen SHA — retiring the manual `git push origin
  # origin/main:refs/heads/accepted` the conductor ran by hand after every ship.
  # Guarded (only where accepted exists), fail-closed (no --force), NON-FATAL (a
  # failed advance never aborts a live ship). These are the proofs on a REAL git
  # fixture.

  # [integration] The core acceptance: with an origin/accepted present, it advances
  # to the shipped SHA alongside main. accepted starts BEHIND at the base commit, so
  # reaching the frozen SHA proves the advance actually pushed.
  def test_push_frozen_main_advances_origin_accepted_when_it_exists
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # accepted exists on origin, sitting BEHIND at the base commit.
      run_git(clone, "push", "-q", "origin", "main:accepted")

      # The frozen SHA is one commit ahead — a real fast-forward for BOTH main and
      # accepted, so reaching it proves the ref push happened.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", out
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "origin/main must reach the frozen SHA"
      assert_equal frozen, git_out(origin, "rev-parse", "accepted"),
                   "origin/accepted must be re-baselined onto the shipped SHA"
      refute_equal base, git_out(origin, "rev-parse", "accepted"),
                   "accepted must have actually advanced off its stale base"
    end
  end

  # [integration] GUARDED. A repo with no origin/accepted (rolio/turf pre-Phase-5)
  # is a clean no-op — main advances, and NO accepted branch is conjured into being.
  def test_push_frozen_main_is_a_clean_noop_on_accepted_when_the_branch_is_absent
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      frozen = git_out(clone, "rev-parse", "release")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", out
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "main still advances for a repo with no accepted branch"
      _, status = Open3.capture2e("git", "-C", origin, "rev-parse", "--verify", "--quiet", "refs/heads/accepted")
      refute status.success?, "no accepted branch may be created for a repo that had none"
    end
  end

  # [integration] NON-FATAL + FAIL-CLOSED. A DIVERGED accepted (a commit the frozen
  # SHA cannot fast-forward onto) must NOT abort the ship and must NOT be force-
  # rewound: main still advances, the warning names the refusal, and accepted is
  # left exactly as it was — the same best-effort contract as the merged:main stamp.
  def test_push_frozen_main_accepted_advance_is_non_fatal_and_never_forces
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # The frozen SHA: one commit ahead of base on release.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # accepted has DIVERGED off base on its own line — the frozen SHA cannot
      # fast-forward onto it, so the advance must refuse rather than --force.
      run_git(clone, "checkout", "-q", "-b", "accepted-work", base)
      File.write(File.join(clone, "hotfix.txt"), "pushed straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted-work:accepted")
      diverged = git_out(origin, "rev-parse", "accepted")

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "a diverged accepted must NOT abort the ship: #{out}"
      refute_includes out, "ABORTED", "the accepted advance is non-fatal — it never aborts the deploy"
      assert_includes out, "NOT forcing", "the warning must say it refused to force accepted"
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "main still advances to the frozen SHA — the accepted failure doesn't block the deploy"
      assert_equal diverged, git_out(origin, "rev-parse", "accepted"),
                   "a diverged accepted must be left EXACTLY as it was — never force-rewound"
    end
  end

  # [integration] REGRESSION (rel-20260720-1fc111): accepted AHEAD, not diverged.
  #
  # A review pass merged two PRs into accepted WHILE the ship ran — a lane the
  # pipeline explicitly supports. The advance correctly refused the non-ff, then
  # mislabelled it "DIVERGED" and suggested `git push origin <sha>:refs/heads/accepted`.
  # Running that would have DESTROYED both merges. accepted was missing NOTHING.
  #
  # The fixture reproduces the exact topology that defeats a naive ancestor check:
  # the sweep merges accepted INTO release (--no-ff), so the frozen main is a MERGE
  # COMMIT whose tree equals the accepted head it came from — and that merge commit
  # is never in accepted's history. `merge-base --is-ancestor` is FALSE here (the
  # test asserts it) even though every byte of main is already in accepted.
  def test_push_frozen_main_reports_accepted_ahead_and_suggests_nothing
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # accepted carries the work that is about to ship.
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "work that ships")
      run_git(clone, "push", "-q", "origin", "accepted")
      absorbed = git_out(clone, "rev-parse", "accepted")

      # The sweep: accepted merged INTO release with --no-ff → a merge commit whose
      # TREE equals accepted's, but which accepted's own history never contains.
      run_git(clone, "checkout", "-q", "release")
      run_git(clone, "merge", "-q", "--no-ff", "-m", "sweep: accepted → release", "accepted")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")
      assert_equal git_out(clone, "rev-parse", "#{absorbed}^{tree}"),
                   git_out(clone, "rev-parse", "#{frozen}^{tree}"),
                   "fixture precondition: the sweep merge's tree equals the accepted head it came from"

      # Concurrent review merges land on accepted DURING the ship — one brand-new
      # file and one MODIFICATION of an already-shipped file (the real incident had
      # both: a new module plus an index entry). CRUCIALLY they arrive from a SEPARATE
      # clone, as a review pass on another machine does, so the ship's own clone never
      # fetches them and its origin/accepted stays STALE at `absorbed`. A same-clone
      # push (rounds 1-3) freshened that ref in a way production never does and hid a
      # missing fetch in the classifier — the round-4 gap that printed "AHEAD by 0
      # commits" against a truth of 13.
      ahead = land_concurrent_merge_on_accepted(dir, origin, label: "ahead",
                                                files: { "zap-protocol.md" => "merged mid-ship",
                                                         "shipped.rb" => "shipped\nindex entry added mid-ship" })

      # The staleness, pinned as the fixture precondition: the ship's clone still
      # sees the PRE-merge accepted, while the true origin has moved ahead of it.
      assert_equal absorbed, git_out(clone, "rev-parse", "origin/accepted"),
                   "fixture precondition: the ship's clone must have a STALE origin/accepted (it never fetched the concurrent merge)"
      refute_equal absorbed, ahead,
                   "fixture precondition: the TRUE origin/accepted moved ahead of what the ship's clone last saw"

      # The subtlety, pinned: plain ancestry says NO even though nothing is missing.
      _, ancestry = Open3.capture2e("git", "-C", clone, "merge-base", "--is-ancestor", frozen, ahead)
      refute ancestry.success?,
             "fixture precondition: the sweep merge commit is NOT an ancestor of accepted"

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "an accepted that is merely ahead must NOT abort the ship: #{out}"
      # THE ROUND-4 LOCK: the count must reflect the TRUE accepted, which the ship can
      # only see if it FETCHES first. Against the stale ref this reads "0 commits"
      # while claiming work merged concurrently — self-contradictory. Only the fetch
      # makes it honest.
      assert_match(/AHEAD of main by 1 commit\b/, out,
                   "the report must name the AHEAD relation and the TRUE commit count (needs a fetch): #{out}")
      refute_match(/DIVERGED|missing shipped content/, out,
                   "accepted is ahead, not diverged — no missing-content alarm may appear: #{out}")
      refute_includes out, "refs/heads/accepted",
                       "NOTHING may be suggested when accepted is ahead — a bare ref push here DESTROYS merged work"
      refute_includes out, "reconcile",
                       "an ahead accepted needs no reconciliation at all: #{out}"
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "main still advances to the frozen SHA"
      assert_equal ahead, git_out(origin, "rev-parse", "accepted"),
                   "the concurrently-merged work on accepted must be left EXACTLY as it was"
    end
  end

  # [integration] REGRESSION (rel-20260720-1fc111), the OTHER shape: accepted is
  # GENUINELY missing shipped content. The report must still say so — but must
  # suggest a MERGE of main into accepted, never a bare ref push, which would
  # discard whatever accepted holds that main does not.
  def test_push_frozen_main_advises_a_merge_when_accepted_is_genuinely_missing_shipped_content
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # The frozen SHA carries content that never reached accepted.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # accepted went its own way off base and never absorbed the shipped file.
      run_git(clone, "checkout", "-q", "-b", "accepted-work", base)
      File.write(File.join(clone, "hotfix.txt"), "pushed straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted-work:accepted")
      diverged = git_out(origin, "rev-parse", "accepted")

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "a genuinely diverged accepted must NOT abort the ship: #{out}"
      assert_includes out, "appears to be missing shipped content",
                      "genuine divergence must be reported as missing shipped content: #{out}"
      assert_match(/git -C .* merge/, out,
                   "the reconcile advice must be a MERGE of main into accepted: #{out}")
      refute_match(/push origin \h+:refs\/heads\/accepted/, out,
                   "a bare ref push must NEVER be suggested — it discards accepted's own commits: #{out}")
      assert_equal diverged, git_out(origin, "rev-parse", "accepted"),
                   "a diverged accepted must be left EXACTLY as it was"
    end
  end

  # [integration] BLOCKER (round 2). The DIVERGED reconcile advice must WORK on a
  # real primary — one that already has a STALE LOCAL `accepted` branch.
  #
  # The round-1 advice (`fetch && checkout accepted && merge origin/main && push
  # origin accepted`) failed exactly there, and NOT for want of a fetch: `git fetch`
  # moves the remote-tracking ref origin/accepted, but `git checkout accepted` lands
  # on the LOCAL branch, which the fetch never touches. The hub primary carries that
  # stale local ref (measured 45 commits behind), so the merge lands on a stale base
  # and the push is refused non-fast-forward. It only ever worked on a checkout with
  # NO local accepted, where `checkout accepted` DWIMs off the remote — which is why
  # it passed round-1 testing and would have failed the operator under ship pressure.
  #
  # This pins the stale-local case by RUNNING the printed command end to end.
  def test_printed_reconcile_command_works_against_a_stale_local_accepted_branch
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # The frozen SHA carries content accepted never absorbed.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # accepted diverges on its own line, and the checkout keeps a LOCAL accepted
      # pinned at that first commit — the operator's primary, exactly.
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "hotfix.txt"), "straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted")
      stale_local = git_out(clone, "rev-parse", "accepted")

      # origin/accepted then moves on WITHOUT the local ref following it.
      second = File.join(dir, "second")
      system("git", "clone", "-q", origin, second, out: File::NULL, err: File::NULL) || flunk("second clone failed")
      run_git(second, "checkout", "-q", "accepted")
      File.write(File.join(second, "review-merge.md"), "merged by review")
      run_git(second, "add", "review-merge.md")
      run_git(second, "commit", "-q", "-m", "review merge")
      run_git(second, "push", "-q", "origin", "accepted")
      run_git(clone, "fetch", "-q", "origin")
      run_git(clone, "checkout", "-q", "main")

      assert_equal stale_local, git_out(clone, "rev-parse", "accepted"),
                   "fixture precondition: the LOCAL accepted stayed put across the fetch"
      refute_equal stale_local, git_out(clone, "rev-parse", "origin/accepted"),
                   "fixture precondition: origin/accepted moved ahead of the stale local ref"

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "appears to be missing shipped content", "this fixture is a genuine divergence: #{out}"
      assert_match(/worktree add --detach \S+ origin\/accepted/, out,
                   "the merge must be based on the REMOTE-TRACKING ref, never the stale local branch: #{out}")

      ok, result, failed = run_printed_reconcile(out)
      assert ok, "the printed reconcile must SUCCEED on a stale local accepted (failed at #{failed}): #{result}"

      # The proof: origin/accepted actually moved, and holds BOTH sides.
      reconciled = git_out(origin, "rev-parse", "accepted")
      refute_equal stale_local, reconciled, "origin/accepted must actually advance"
      %w[shipped.rb hotfix.txt review-merge.md].each do |file|
        _, present = Open3.capture2e("git", "-C", origin, "cat-file", "-e", "accepted:#{file}")
        assert present.success?, "#{file} must survive the reconcile — nothing may be discarded"
      end
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the recovery must leave the primary back on main, not stranded on a reconcile branch"
    end
  end

  # [integration] The post-#588 GEM-CARRYING RELEASE. bump_consumer_locks_for_qa
  # commits consumer lockfile bumps onto `release` during prepare, so the frozen
  # tree legitimately differs from accepted's head tree — tree absorption is truly
  # REFUTED and the refusal lands on :diverged. That verdict is CORRECT (accepted
  # really is missing the lock bump), and #588 makes it the common path, so the
  # advice it prints has to work here too.
  def test_gem_carrying_release_reports_diverged_truthfully_with_working_advice
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # accepted carries the work that ships.
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "work that ships")
      run_git(clone, "push", "-q", "origin", "accepted")

      # The sweep merges accepted into release...
      run_git(clone, "checkout", "-q", "release")
      run_git(clone, "merge", "-q", "--no-ff", "-m", "sweep: accepted → release", "accepted")
      # ...and then #588's prepare commits the consumer lock bump ON TOP, on release
      # only. From here the frozen tree can never equal any accepted tree.
      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.4.2)")
      run_git(clone, "add", "Gemfile.lock")
      run_git(clone, "commit", "-q", "-m", "bump consumer lock for QA")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # A concurrent review merge lands on accepted from a SEPARATE clone, so the
      # advance is refused — and the ship's clone keeps a STALE origin/accepted, as
      # in production. (Round-4 sweep: this fixture pushed the concurrent merge from
      # the SAME clone, freshening the ref and masking the missing fetch.)
      run_git(clone, "checkout", "-q", "main")
      land_concurrent_merge_on_accepted(dir, origin, label: "gem",
                                        files: { "review-merge.md" => "merged by review" })

      refute_equal git_out(origin, "rev-parse", "#{frozen}^{tree}"),
                   git_out(origin, "rev-parse", "accepted^{tree}"),
                   "fixture precondition: the lock bump makes the frozen tree differ from the TRUE accepted's"

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "a gem-carrying release must not abort the ship: #{out}"
      assert_includes out, "appears to be missing shipped content",
                      "accepted genuinely lacks the lock bump — the missing-content verdict is TRUE here: #{out}"
      refute_includes out, "UNDETERMINED",
                      "the signals are readable — a true refutation is not an unknown: #{out}"

      ok, result, failed = run_printed_reconcile(out)
      assert ok, "the printed reconcile must work on the shape #588 made common (failed at #{failed}): #{result}"
      %w[shipped.rb Gemfile.lock review-merge.md].each do |file|
        _, present = Open3.capture2e("git", "-C", origin, "cat-file", "-e", "accepted:#{file}")
        assert present.success?, "#{file} must survive the reconcile — the lock bump is the point"
      end
    end
  end

  # [integration] BLOCKER (round 3). THE FAILING PATH. Every advice test before this
  # one executed the recipe against a fixture that merges CLEANLY — they prove the
  # advice works for shapes we already imagined. The invariant is stronger: the
  # printed advice must never STRAND the operator, for ANY merge outcome.
  #
  # This is not a corner. This PR's own docs declare :diverged the ROUTINE outcome on
  # a gem-carrying release, and the mechanism is a Gemfile.lock bump — the file most
  # likely to have been touched on accepted too. The routine path IS the conflict
  # path. The round-2 recipe was an && chain, so `git merge` exiting non-zero halted
  # it: no push, no `checkout main`, operator left on an unfamiliar branch mid-
  # conflict with a DIRTY primary — which on a gem repo also aborts the NEXT ship.
  #
  # So this asserts the operator is TOLD WHAT TO DO and left RECOVERABLE, not that
  # the chain succeeds. Both sides genuinely touch the same line of Gemfile.lock.
  def test_printed_reconcile_fails_safe_and_instructs_when_the_merge_conflicts
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")

      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.4.0)\n")
      run_git(clone, "add", "Gemfile.lock")
      run_git(clone, "commit", "-q", "-m", "lock 0.4.0")
      run_git(clone, "push", "-q", "origin", "main")
      # release must DESCEND from main, or the frozen SHA is not a fast-forward of it.
      run_git(clone, "branch", "-f", "release", "main")
      run_git(clone, "push", "-q", "-f", "origin", "release")
      base = git_out(clone, "rev-parse", "main")

      # accepted bumps the lock one way (a feature branch merged there)...
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.4.1)\n")
      run_git(clone, "add", "Gemfile.lock")
      run_git(clone, "commit", "-q", "-m", "accepted: lock 0.4.1")
      run_git(clone, "push", "-q", "origin", "accepted")
      accepted_head = git_out(origin, "rev-parse", "accepted")

      # ...and #588's prepare bumps the SAME line another way on the shipped side.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.5.0)\n")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "prepare: bump consumer lock for QA")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")
      run_git(clone, "checkout", "-q", "main")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "a conflicting reconcile must not abort the ship: #{out}"

      # The recipe is NOT an && chain any more — a chain implies all-or-nothing.
      refute_match(/^ {6}git -C \S+ fetch origin &&/, out,
                   "the recipe must not be a single && chain: a conflict halts it silently: #{out}")

      # Follow it top to bottom, as an operator would. It STOPS at the merge...
      ok, result, failed = run_printed_reconcile(out)
      refute ok, "fixture precondition: this merge must genuinely conflict"
      assert_match(/merge origin\/main/, failed, "it must stop at the MERGE step, not earlier: #{failed}")
      assert_match(/CONFLICT|Automatic merge failed/, result, "the operator must see the conflict named: #{result}")

      # ...and THAT IS SAFE, which is the whole point. The primary never moved.
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary must still be on main — never stranded on a reconcile branch"
      assert_empty git_out(clone, "status", "--porcelain"),
                   "the primary must still be CLEAN — a dirty gem primary ABORTS the next ship"
      assert_equal accepted_head, git_out(origin, "rev-parse", "accepted"),
                   "origin/accepted must be untouched — no half-finished reconcile"

      # The operator is TOLD WHAT TO DO, both ways, rather than left to invent it.
      assert_match(/IF THE MERGE CONFLICTS/, out, "the conflict case must be named up front: #{out}")
      finish = printed_finish_command(out)
      bailout = printed_bailout_command(out)
      assert finish,  "a FINISH IT instruction must be printed: #{out}"
      assert bailout, "a BAIL OUT instruction must be printed: #{out}"

      # BAIL OUT genuinely restores a clean machine.
      _, bail_status = Open3.capture2e("bash", "-c", bailout)
      assert bail_status.success?, "the printed BAIL OUT must succeed"
      assert_empty git_out(clone, "status", "--porcelain"), "bailing out must leave the primary clean"
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"), "bailing out must leave main checked out"
      refute_match(/reconcile/, git_out(clone, "worktree", "list"),
                   "bailing out must leave NO worktree residue behind")

      # And FINISH IT genuinely completes the reconcile after a resolution.
      _, status = Open3.capture2e("bash", "-c", printed_reconcile_steps(out)[1])
      assert status.success?, "re-creating the scratch worktree must succeed after a bail out"
      scratch = File.join(dir, "scratch-reconcile")
      Open3.capture2e("bash", "-c", printed_reconcile_steps(out)[2])
      File.write(File.join(scratch, "Gemfile.lock"), "studio-engine (0.5.0)\n")
      _, finish_status = Open3.capture2e("bash", "-c", finish)
      assert finish_status.success?, "the printed FINISH IT must complete the reconcile after a resolution"

      %w[shipped.rb Gemfile.lock].each do |file|
        _, present = Open3.capture2e("git", "-C", origin, "cat-file", "-e", "accepted:#{file}")
        assert present.success?, "#{file} must be on accepted after finishing the reconcile"
      end
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "finishing the reconcile must also leave the primary on main"
      assert_empty git_out(clone, "status", "--porcelain"), "finishing must leave the primary clean"
    end
  end

  # [integration] ABSENCE of signal is not a NEGATIVE signal. When the git reads
  # cannot resolve the relation, the ship must say UNDETERMINED and tell the
  # operator to check — never assert a confident DIVERGED it cannot support. This
  # is the same shape as the original defect, one layer down.
  def test_unreadable_relation_reports_undetermined_rather_than_guessing_diverged
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      base   = git_out(clone, "rev-parse", "main")

      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      run_git(clone, "checkout", "-q", "-b", "accepted-work", base)
      File.write(File.join(clone, "hotfix.txt"), "straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted-work:accepted")

      # The relation becomes UNREADABLE: the remote-tracking ref will not resolve.
      setup = %(def repo_path(_repo) = #{clone.inspect}\n) +
              %(def rev_parse_ok?(_path, ref) = !ref.to_s.include?("origin/accepted")\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "an unreadable relation must NOT abort the ship: #{out}"
      assert_includes out, "UNDETERMINED", "an unreadable relation must be reported as such: #{out}"
      refute_match(/appears to be missing shipped content/, out,
                   "an unreadable state must never be asserted as genuine divergence: #{out}")
      refute_includes out, "AHEAD of main",
                      "nor may it claim accepted is ahead — the point is that we do not know: #{out}"
      refute_match(/push origin \h+:refs\/heads\/accepted/, out,
                   "no bare ref push, in any state: #{out}")
    end
  end

  # ------------------------------------------------ push failure diagnosis ----
  #
  # THE DEFECT THIS PINS. Measured 2026-08-29, twice, on a real production ship:
  # `git push` failed on CREDENTIALS (`remote: Invalid username or token`) and
  # push_frozen_main answered "origin/main has diverged from the frozen SHA
  # (someone pushed to main) ... reconcile main, re-run prepare to re-freeze".
  # Nothing had diverged — main was strictly BEHIND release and a dry-run
  # fast-forward succeeded — so the prescribed remedy was pure waste, delivered
  # with complete confidence at the most expensive moment in the pipeline. git had
  # already named the true cause three lines above; the code discarded it.

  def test_a_credential_refusal_is_diagnosed_as_auth_not_as_a_divergence
    output = <<~GIT
      remote: Invalid username or token. Password authentication is not supported for Git operations.
      fatal: Authentication failed for 'https://github.com/McRitchie-Studio/mcritchie-studio/'
      error: failed to push some refs to 'https://github.com/McRitchie-Studio/mcritchie-studio'
    GIT

    assert_equal "auth", eval_helper(%(classify_push_failure(#{output.inspect})))
  end

  # A helper that cannot resolve its host leaves git saying `could not read
  # Username`, an auth sign; the network line beside it decides.
  def test_dns_failure_classifies_network
    dns = <<~GIT
      gh-app-git-credential: getaddrinfo: nodename nor servname provided, or not known
      fatal: could not read Username for 'https://github.com': terminal prompts disabled
    GIT
    assert_equal "network", eval_helper(%(classify_push_failure(#{dns.inspect})))
    assert_equal "network",
                 eval_helper(%(classify_push_failure("fatal: unable to access 'https://github.com/x/y/': Could not resolve host: github.com")))
    assert_equal "network",
                 eval_helper(%(classify_push_failure("fatal: unable to access 'https://github.com/x/y/': Operation timed out")))

    # The controls: the same refusals with no network line stay auth.
    assert_equal "auth",
                 eval_helper(%(classify_push_failure("fatal: could not read Username for 'https://github.com': terminal prompts disabled")))
    assert_equal "auth", eval_helper(%(classify_push_failure("remote: Invalid username or token.")))
  end

  def test_the_network_message_prescribes_neither_standard_remedy
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :network)))

    assert_includes msg, "NETWORK failure"
    assert_includes msg, "not a credential refusal and not a divergence"
    assert_includes msg, "do NOT re-run `prepare`"
    refute_includes msg, "REFUSED ON CREDENTIALS"
  end

  # `error: failed to push some refs to ...` appears in BOTH failures, so it can
  # never be the discriminator. This is that line ALONE, with no cause: it must
  # come back unknown rather than be guessed at.
  def test_the_shared_failure_line_alone_is_not_classified
    assert_equal "unknown",
                 eval_helper(%(classify_push_failure("error: failed to push some refs to 'https://github.com/x/y'")))
  end

  def test_a_real_non_fast_forward_is_still_diagnosed_as_a_divergence
    output = <<~GIT
      To https://github.com/McRitchie-Studio/mcritchie-studio
       ! [rejected]        abc123 -> main (non-fast-forward)
      error: failed to push some refs to 'https://github.com/McRitchie-Studio/mcritchie-studio'
    GIT

    assert_equal "diverged", eval_helper(%(classify_push_failure(#{output.inspect})))
  end

  def test_a_stale_ref_rejection_is_a_divergence
    output = " ! [rejected]        abc123 -> main (fetch first)\n"

    assert_equal "diverged", eval_helper(%(classify_push_failure(#{output.inspect})))
  end

  # An unrecognised cause must SAY it is unrecognised. Guessing is the whole
  # defect; a silent fallback to either standard remedy would reproduce it.
  def test_an_unrecognised_failure_is_reported_as_unrecognised
    assert_equal "unknown", eval_helper(%(classify_push_failure("fatal: the remote end hung up unexpectedly")))
    assert_equal "unknown", eval_helper(%(classify_push_failure("")))
  end

  def test_the_divergence_message_still_prescribes_the_reconcile
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :diverged)))

    assert_includes msg, "NON-FAST-FORWARD"
    assert_includes msg, "bin/release prepare"
    assert_includes msg, "NOT forcing"
  end

  # The honest third answer. It must not quietly prescribe either standard remedy.
  def test_the_unknown_message_prescribes_neither_remedy
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :unknown)))

    assert_includes msg, "NOT one this script recognises"
    assert_includes msg, "NOT forcing"
    assert_match(/may be the wrong errand/, msg)
  end
end

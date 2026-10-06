# frozen_string_literal: true

# The auto-repin pass, merge-forward across repos, and partial-ship retries.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_repin_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliRepinTest < ReleaseCliHarness
  # [integration] THE regression: the primary's stale `main` says "already pinned",
  # the frozen tree says "branch-ref'd". The ship must believe the FROZEN TREE and
  # re-pin — never print "already pinned" and ship a branch-ref'd Gemfile to prod.
  def test_repin_decides_from_the_frozen_tree_not_the_stale_primary
    Dir.mktmpdir do |dir|
      clone, frozen = build_repin_fixture(dir)
      # Prove the trap is armed: read the PRIMARY and you conclude "nothing to do".
      assert_match(/~> 0\.8/, File.read(File.join(clone, "Gemfile")),
                   "the primary's main must look ALREADY PINNED — that is the lie the old code believed")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPING " + sha["sibling"])})

      refute_includes out, "already pinned",
                      "the stale primary must NOT be allowed to say 'nothing to do': #{out}"
      shipped = out[/SHIPPING (\h{40})/, 1]
      refute_nil shipped, "the re-pin must advance the ship SHA: #{out}"
      refute_equal frozen, shipped, "the ship SHA must move to the re-pin commit"

      # What actually ships: the re-pin commit, on top of frozen, with a REAL pin.
      gemfile = git_out(clone, "show", "#{shipped}:Gemfile")
      assert_match(/studio-engine.*~> 0\.9/, gemfile,
                   "prod must build the PUBLISHED gem — not a git branch")
      refute_match(/branch:/, gemfile, "no branch ref may reach production")
      assert_equal frozen, git_out(clone, "rev-parse", "#{shipped}^"),
                   "the re-pin must sit directly on the QA-frozen SHA — nothing else rides out with it"
      assert_equal shipped, git_out(File.join(dir, "origin.git"), "rev-parse", "release"),
                   "…and be pushed to origin/release"
    end
  end

  # [integration] THE regression: a dirty primary must NOT stop the merge-forward,
  # and the merge must actually land on origin/release.
  def test_merge_forward_lands_despite_a_dirty_primary_checkout
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir)
      origin = File.join(dir, "origin.git")
      refute_equal git_out(origin, "rev-parse", "main"), git_out(origin, "rev-parse", "release"),
                   "precondition: release must be BEHIND main"

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "PASSED", "a dirty primary must not defeat the guard: #{out}"
      assert system("git", "-C", origin, "merge-base", "--is-ancestor",
                    git_out(origin, "rev-parse", "main"), "release",
                    out: File::NULL, err: File::NULL),
             "origin/release must CONTAIN origin/main after the guard runs"

      # The primary is untouched: same branch, and the uncommitted work survives.
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the guard must never flip the primary's HEAD"
      assert_equal "uncommitted work from another session\n", File.read(File.join(clone, "README")),
                   "another session's uncommitted work must survive the merge-forward"
    end
  end

  # [integration] GEM repos ride the guard. A gem keeps the same release branch
  # and ship workspace as an app, and `bin/release ship` fast-forwards its main
  # via the same non-forced ref push — so a gem main hotfix left unmerged
  # dead-ends the ship at G4 exactly like an app's. A gem group ALONE must drive
  # the merge (the guard takes gem_groups alongside app_groups).
  def test_merge_forward_covers_gem_repos
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir)
      origin = File.join(dir, "origin.git")
      refute_equal git_out(origin, "rev-parse", "main"), git_out(origin, "rev-parse", "release"),
                   "precondition: the gem's release must be BEHIND its main"

      call = %{begin; merge_forward_release_branches([], gem_groups: [{ "repo" => "sibling" }]); } +
             %{puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end}
      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: call)

      assert_includes out, "PASSED", "a gem group alone must drive the guard: #{out}"
      assert system("git", "-C", origin, "merge-base", "--is-ancestor",
                    git_out(origin, "rev-parse", "main"), "release",
                    out: File::NULL, err: File::NULL),
             "the GEM repo's origin/release must CONTAIN origin/main after the guard runs"
    end
  end

  # [integration] Already contained → a clean no-op that pushes nothing.
  def test_merge_forward_is_a_no_op_when_release_already_contains_main
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir) # main == release out of the box
      origin = File.join(dir, "origin.git")
      before = git_out(origin, "rev-parse", "release")

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "PASSED"
      assert_equal before, git_out(origin, "rev-parse", "release"),
                   "nothing may be pushed when main is already contained"
      refute_includes out, "main moved ahead"
    end
  end

  # [integration] A CONFLICT must abort loudly, push nothing, and leave the
  # primary alone — the old guard's failure was continuing non-fatally.
  def test_merge_forward_aborts_on_a_conflict_and_pushes_nothing
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir, conflicting: true)
      origin = File.join(dir, "origin.git")
      before = git_out(origin, "rev-parse", "release")

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "ABORTED", "a conflicted merge-forward must abort, never continue: #{out}"
      assert_includes out, "merge-forward CONFLICT"
      assert_includes out, "no primary checkout was touched"
      # …and the claim is SCOPED: it speaks for this repo, not the whole sweep.
      assert_includes out, "Nothing was pushed FOR sibling",
                      "the abort must not claim the sweep left nothing behind"
      refute_includes out, "PASSED"

      assert_equal before, git_out(origin, "rev-parse", "release"),
                   "a conflicted merge must push NOTHING"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary stays where the operator left it"
    end
  end

  # [integration] A FAILED FETCH must fail CLOSED, not judge containment from a
  # stale ref. This is the clause guarding the very incident class: origin/main is
  # how we learn what production carries, so a fetch that did not run means the
  # answer describes an older world.
  def test_merge_forward_fails_closed_when_the_pre_check_fetch_fails
    Dir.mktmpdir do |dir|
      clone = build_merge_forward_fixture(dir)
      # Point origin at nothing: the fetch cannot succeed.
      run_git(clone, "remote", "set-url", "origin", File.join(dir, "no-such-origin.git"))

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "ABORTED", "a failed fetch must abort, not proceed on a stale ref: #{out}"
      assert_includes out, "refusing to judge merge-forward"
      refute_includes out, "PASSED"
    end
  end

  # [integration] A FAILED PUSH must abort. The merge succeeded locally, but the
  # branch never moved — proceeding would gate and deploy a tree that still lacks
  # the hotfix.
  def test_merge_forward_aborts_when_the_push_is_refused
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir)
      origin = File.join(dir, "origin.git")
      before = git_out(origin, "rev-parse", "release")
      # Refuse every push into the bare origin.
      hook = File.join(origin, "hooks", "pre-receive")
      FileUtils.mkdir_p(File.dirname(hook))
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "ABORTED", "a refused push must abort: #{out}"
      assert_includes out, "could not push the merge-forward"
      refute_includes out, "PASSED"
      assert_equal before, git_out(origin, "rev-parse", "release"), "release must not have moved"
    end
  end

  # [integration] MULTI-REPO: the guard runs per app, and one repo's success must
  # not mask another's failure. The second repo conflicts; the first has already
  # merged and pushed — which is exactly why the abort text must not claim
  # "nothing was pushed" at sweep grain.
  def test_merge_forward_across_two_repos_aborts_on_the_second_and_says_what_landed
    Dir.mktmpdir do |dir_a|
      Dir.mktmpdir do |dir_b|
        clone_a = build_merge_forward_fixture(dir_a)
        clone_b = build_merge_forward_fixture(dir_b, conflicting: true)
        origin_a = File.join(dir_a, "origin.git")

        setup = <<~RUBY
          PATHS = { "a" => #{clone_a.inspect}, "b" => #{clone_b.inspect} }
          def repo_path(repo) = PATHS.fetch(repo)
        RUBY
        out = run_cli(["--yes"], setup: setup,
                      call: %{begin; merge_forward_release_branches([{ "repo" => "a" }, { "repo" => "b" }]); } +
                            %{puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

        assert_includes out, "ABORTED", "the second repo's conflict must abort the sweep: #{out}"
        assert_includes out, "merge-forward CONFLICT in b"
        refute_includes out, "PASSED"

        # Repo A really did land, so the message must not imply a clean slate.
        assert system("git", "-C", origin_a, "merge-base", "--is-ancestor",
                      git_out(origin_a, "rev-parse", "main"), "release",
                      out: File::NULL, err: File::NULL),
               "repo a's merge-forward landed before b failed"
        assert_includes out, "earlier repo's merge-forward",
                        "the abort must warn that earlier work already landed"
        assert_includes out, "Do NOT `reset`",
                        "and must steer the operator off the destructive cleanup"
      end
    end
  end

  def test_a_dirty_primary_cannot_force_a_repin_the_frozen_tree_does_not_need
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.9"\n))
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "release: already pinned")
      run_git(clone, "push", "-q", "origin", "main")
      frozen = git_out(clone, "rev-parse", "HEAD")

      # A live session's floor: off main, and its Gemfile branch-refs the gem.
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "Gemfile"),
                 %(source "https://rubygems.org"\ngem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "wip"\n))

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("PASSED " + sha["sibling"]); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "a dirty primary must not abort the re-pin AFTER the gems published: #{out}"
      assert_includes out, "already pinned", "the FROZEN tree is already pinned — there is nothing to do"
      assert_includes out, "PASSED #{frozen}", "the ship SHA must not move"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary is never checked out"
    end
  end
  # [integration] THE fix: the retry REUSES the re-pin already on origin/release,
  # mints no rival commit, and ships it. Before the fix this aborted.
  def test_a_partial_ship_retry_reuses_the_repin_already_on_release
    Dir.mktmpdir do |dir|
      clone, frozen, repin1 = build_partial_ship_fixture(dir)
      origin = File.join(dir, "origin.git")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPING " + sha["sibling"])})

      assert_includes out, "ALREADY on origin/release", "the retry must RECOGNIZE its own prior re-pin: #{out}"
      assert_includes out, "SHIPPING #{repin1}",
                       "…and ship THAT commit — the act is already done, not to be done twice"
      assert_equal repin1, git_out(origin, "rev-parse", "release"),
                   "no rival commit may be pushed — a second re-pin is a non-fast-forward that can never land"
    end
  end

  # [integration] FAILS CLOSED on genuine drift: a real CODE commit landed on
  # release after the freeze. That is exactly what the guard exists for — it must
  # still abort, and must not mistake a code commit for a mechanical re-pin.
  def test_a_retry_still_aborts_when_real_code_drifted_onto_release
    Dir.mktmpdir do |dir|
      clone, frozen, = build_partial_ship_fixture(dir)
      # …and someone merged real code on top of the re-pin, post-freeze.
      run_git(clone, "checkout", "-q", "--detach", git_out(clone, "rev-parse", "origin/release"))
      File.write(File.join(clone, "app.rb"), "un-QA'd feature")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "a feature that never went through QA")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
      drifted = git_out(clone, "rev-parse", "HEAD")
      run_git(clone, "checkout", "-q", "main")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPED " + sha["sibling"]); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "un-QA'd code on release must still abort the ship: #{out}"
      assert_includes out, "un-QA'd", "…and say why"
      refute_includes out, "REUSING", "a code commit is NOT a mechanical re-pin"
      assert_equal drifted, git_out(File.join(dir, "origin.git"), "rev-parse", "release"),
                   "the ship must not have pushed anything"
    end
  end

  # [integration] The IDENTITY check, not a "looks pinned" check. A Gemfile-only
  # commit on release that pins the WRONG version has no branch ref left — so a
  # weaker "nothing left to re-pin?" test would wave it through and prod would build
  # 0.7. Byte-identity to what THIS run would write is the only safe standard.
  def test_a_retry_aborts_when_release_pins_a_version_this_ship_did_not_publish
    Dir.mktmpdir do |dir|
      clone, frozen = build_repin_fixture(dir)
      run_git(clone, "checkout", "-q", "--detach", frozen)
      File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.7"\n))
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "pinned — but to a version this ship never published")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
      run_git(clone, "checkout", "-q", "main")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED",
                      "a Gemfile pinned to a version this ship never published must NOT be reused: #{out}"
      refute_includes out, "REUSING", "'no branch ref left' is not the same as 'this is my re-pin'"
    end
  end
end

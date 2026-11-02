# frozen_string_literal: true

# THE SWEPT PIN, against REAL git. prepare pins each member repo's `accepted` head right after
# detection; the promote lands that SHA, the record carries it, and the gate asserts `release`
# contains it. A post-sweep merge waits for the next release; swept work missing from
# `release` still refuses, as does any `accepted` work in a repo with no pin. Every git
# command is real against a bare origin; only `gh`, the board and the CI guards are stubbed.
# History: task release-pins-swept-sha.

require_relative "release_cli_harness"
require_relative "../../bin/lib/release_cycle"

class ReleaseSweptPinTest < ReleaseCliHarness
  REPO = "mcritchie-studio"

  # [integration] The incident: the pin, a merge after it, then the promote and the
  # gate. `release` lands exactly the pin, and the gate passes and names the newcomer
  # as waiting for the next release.
  def test_integration_a_merge_after_the_sweep_waits_and_does_not_refuse
    with_ladder do |clone, dir|
      swept = land_on_accepted(clone, "swept.rb", "reviewed and swept")

      out = run_seq(clone, dir, %{
        pin_swept_shas!([#{REPO.inspect}])
        puts("PIN " + swept_pin(#{REPO.inspect}))
        system("git", "-C", #{clone.inspect}, "fetch", "-q", "origin")
        #{land_ruby(clone, 'newcomer.rb', 'merged one minute later')}
        promote_accepted_to_release!([#{REPO.inspect}])
        verify_release_carries_accepted!([{ "repo" => #{REPO.inspect} }], "rel-pin", "assembling")
        puts("GATE-PASSED")
      })

      assert_includes out, "PIN #{swept}", "the pin is the head the sweep read"
      assert_includes out, "pin: this release promotes the `accepted` SHA swept now — #{REPO}@#{swept[0, 7]}"
      assert_equal swept, remote_sha(dir, "release"), "the promote lands the pin, not the newcomer"
      refute_equal swept, remote_sha(dir, "accepted"), "the newcomer is on accepted"
      assert_includes out, "GATE-PASSED", "a post-sweep merge must not refuse the release: #{out}"
      refute_includes out, "stale tree"
      assert_includes out, "carries every `accepted` commit this release swept (#{REPO}@#{swept[0, 7]})"
      assert_includes out, "1 commit reached `accepted` after the sweep pinned #{swept[0, 7]}"
      assert_includes out, "the next release sweeps it"
    end
  end

  # [integration] The gate keeps its purpose: work the sweep took that `release`
  # lacks refuses, and the refusal names the pinned SHA.
  def test_integration_swept_work_missing_from_release_still_refuses
    with_ladder do |clone, dir|
      swept = land_on_accepted(clone, "swept.rb", "reviewed and swept")

      out = run_seq(clone, dir, %{
        pin_swept_shas!([#{REPO.inspect}])
        begin
          verify_release_carries_accepted!([{ "repo" => #{REPO.inspect} }], "rel-pin", "assembling")
          puts("GATE-PASSED")
        rescue SystemExit => e
          puts("GATE-REFUSED " + e.message)
        end
      })

      assert_includes out, "GATE-REFUSED", "release lacks the swept commit: #{out}"
      refute_includes out, "GATE-PASSED"
      assert_includes out, "stale tree: `release` does not carry `accepted` (the swept SHA: #{REPO}@#{swept[0, 7]})"
      assert_includes out, "work this release SWEPT is missing from it"
      assert_includes out, "1 commit stranded on `accepted` up to the swept #{swept[0, 7]}"
      assert_match ReleaseCycle::STALE_TREE, out, "the cycle still recognises the refusal"
    end
  end

  # [integration] A repo with NO pin keeps the live check: an orphan commit on
  # `accepted` that no promote carried refuses, as on 2026-08-11.
  def test_integration_an_unpinned_repo_keeps_the_live_accepted_check
    with_ladder do |clone, dir|
      land_on_accepted(clone, "orphan.rb", "a zap with no task")

      out = run_seq(clone, dir, %{
        begin
          verify_release_carries_accepted!([{ "repo" => #{REPO.inspect} }], "rel-pin", "assembled")
          puts("GATE-PASSED")
        rescue SystemExit => e
          puts("GATE-REFUSED " + e.message)
        end
      })

      assert_includes out, "GATE-REFUSED"
      assert_includes out, "stale tree: `release` does not carry `accepted` in #{REPO}"
      refute_includes out, "SWEPT", "an unpinned refusal makes no claim about a sweep"
    end
  end

  # [integration] A re-run with nothing to sweep adopts the pins the release recorded,
  # so the newcomers that arrived since do not refuse the self-healing run either.
  def test_integration_a_rerun_adopts_the_recorded_pin
    with_ladder do |clone, dir|
      swept = land_on_accepted(clone, "swept.rb", "reviewed and swept")
      run_git(clone, "push", "-q", "origin", "#{swept}:refs/heads/release")
      land_on_accepted(clone, "newcomer.rb", "merged after the first run")

      out = run_seq(clone, dir, %{
        adopt_recorded_pins!({ #{REPO.inspect} => #{swept.inspect} })
        verify_release_carries_accepted!([{ "repo" => #{REPO.inspect} }], "rel-pin", "assembling")
        puts("GATE-PASSED")
      })

      assert_includes out, "GATE-PASSED", out
      assert_includes out, "1 commit reached `accepted` after the sweep pinned #{swept[0, 7]}"
    end
  end

  # [integration] The rare path: `release` diverged, so the promote is the batch PR,
  # which merges the branch head. A merge after the sweep rides it, the pin advances
  # to the merged head, and the output says so; the merge is pinned to that head.
  def test_integration_the_batch_pr_advances_the_pin_out_loud
    with_ladder do |clone, dir|
      run_git(clone, "checkout", "-q", "--detach", "origin/release")
      File.write(File.join(clone, "hotfix.rb"), "a hotfix on release")
      run_git(clone, "add", "hotfix.rb")
      run_git(clone, "commit", "-qm", "hotfix on release")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
      run_git(clone, "checkout", "-q", "main")
      swept = land_on_accepted(clone, "swept.rb", "reviewed and swept")

      out = run_seq(clone, dir, %{
        pin_swept_shas!([#{REPO.inspect}])
        system("git", "-C", #{clone.inspect}, "fetch", "-q", "origin")
        #{land_ruby(clone, 'newcomer.rb', 'merged mid-promote')}
        promote_accepted_to_release!([#{REPO.inspect}])
        puts("PIN-NOW " + swept_pin(#{REPO.inspect}))
      })

      # The batch PR's merge commit: its second parent is the `accepted` head it merged.
      merged_head = git_out(File.join(dir, "origin.git"), "rev-parse", "#{remote_sha(dir, 'release')}^2")
      refute_equal swept, merged_head, "the newcomer rode the batch merge"
      assert_includes out, "GH-MERGE"
      assert_includes out, "moved past the swept #{swept[0, 7]} to #{merged_head[0, 7]}"
      assert_includes out, "they ride this release; the pin advances"
      assert_includes out, "--match-head-commit #{merged_head}", "the batch merge is pinned to the head it judged"
      assert_includes out, "PIN-NOW #{merged_head}", "the pin describes the merged tree, not the swept one"
    end
  end

  # [integration] A failed fetch pins nothing: the stale local ref can predate a
  # member detection found, and a pin missing swept work would pass the gate.
  def test_integration_a_failed_fetch_pins_nothing
    with_ladder do |clone, dir|
      land_on_accepted(clone, "swept.rb", "reviewed and swept")
      run_git(clone, "remote", "set-url", "origin", File.join(dir, "gone.git"))

      out = run_seq(clone, dir, %{
        pin_swept_shas!([#{REPO.inspect}])
        puts("PIN [" + swept_pin(#{REPO.inspect}) + "]")
      })

      assert_includes out, "PIN []", "a pin read after a failed fetch: #{out}"
    end
  end

  # [unit] The CI credit treats the pin as the accepted head, so a merge after the
  # sweep does not demote the fast-forwarded tip to "diverged" and lose the credit.
  def test_fast_forward_credit_holds_after_accepted_moves
    with_ladder do |clone, dir|
      swept = land_on_accepted(clone, "swept.rb", "reviewed and swept")
      run_git(clone, "push", "-q", "origin", "#{swept}:refs/heads/release")
      land_on_accepted(clone, "newcomer.rb", "merged later")

      out = run_seq(clone, dir, %{
        system("git", "-C", #{clone.inspect}, "fetch", "-q", "origin")
        puts("UNPINNED " + fast_forward_promote?(#{clone.inspect}, #{swept.inspect}, repo: #{REPO.inspect}).to_s)
        adopt_recorded_pins!({ #{REPO.inspect} => #{swept.inspect} })
        puts("PINNED " + fast_forward_promote?(#{clone.inspect}, #{swept.inspect}, repo: #{REPO.inspect}).to_s)
      })

      assert_includes out, "UNPINNED false", "without a pin the moved head is not the release tip"
      assert_includes out, "PINNED true", "the pin is the head CI built for this tip"
    end
  end

  # [integration] The dry run reads the pin through a read (no fetch) and previews the
  # gate against it: no refusal is manufactured from a post-sweep merge.
  def test_integration_prepare_dry_run_reports_the_pinned_sha_and_no_refusal
    with_ladder do |clone, dir|
      swept = land_on_accepted(clone, "swept.rb", "reviewed and swept")
      run_git(clone, "fetch", "-q", "origin")

      setup = <<~RUBY
        def repo_path(_repo) = #{clone.inspect}
        def conductor(ruby, read_only: false)
          if ruby.include?("sweep_candidates")
            return { "tasks" => [{ "slug" => "t-swept", "stage" => "reviewed", "merged" => "accepted",
                                   "pr_url" => "https://gh/pr/2327", "repo" => #{REPO.inspect},
                                   "repos" => [#{REPO.inspect}] }],
                     "release" => { "slug" => "rel-pin", "state" => "assembling" },
                     "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
          end
          { "slug" => "rel-pin", "state" => "assembling", "branch" => "release", "repos" => [
            { "repo" => #{REPO.inspect}, "kind" => "app", "release_branch" => "release",
              "qa_app" => #{REPO.inspect}, "members" => [{ "slug" => "t-swept", "branch" => "feat/swept" }] }
          ] }
        end
      RUBY
      out = run_cli(["--dry-run"], setup: %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) + setup,
                                   call: "begin; prepare; rescue SystemExit; puts('EXITED'); end")

      assert_includes out, "pin: this release promotes the `accepted` SHA swept now — #{REPO}@#{swept[0, 7]}"
      assert_includes out, "as of the last fetch; a dry run takes none"
      assert_includes out, "verify: would check `release` carries `accepted` (the swept SHA: #{REPO}@#{swept[0, 7]})"
      refute_includes out, "prepare refused"
      refute_includes out, "stale tree"
    end
  end

  private

  # A bare origin and a clone whose main, release and accepted start on one commit.
  def with_ladder
    Dir.mktmpdir("release-swept-pin") do |dir|
      origin = File.join(dir, "origin.git")
      clone = File.join(dir, "repo")
      system("git", "init", "--bare", "-q", origin, out: File::NULL, err: File::NULL) || flunk("git init --bare failed")
      system("git", "clone", "-q", origin, clone, out: File::NULL, err: File::NULL) || flunk("git clone failed")
      run_git(clone, "symbolic-ref", "HEAD", "refs/heads/main")
      run_git(clone, "config", "user.email", "t@t.t")
      run_git(clone, "config", "user.name", "t")
      run_git(clone, "config", "commit.gpgsign", "false")
      File.write(File.join(clone, "README.md"), "seed\n")
      run_git(clone, "add", ".")
      run_git(clone, "commit", "-qm", "seed")
      run_git(clone, "push", "-q", "origin", "main", "main:release", "main:accepted")
      yield clone, dir
    end
  end

  # A reviewed change reaching `accepted`, the way review's merge lands.
  def land_on_accepted(clone, file, content)
    run_git(clone, "fetch", "-q", "origin")
    run_git(clone, "checkout", "-q", "--detach", "origin/accepted")
    File.write(File.join(clone, file), content)
    run_git(clone, "add", file)
    run_git(clone, "commit", "-qm", "Merge reviewed #{file}")
    run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/accepted")
    sha = git_out(clone, "rev-parse", "HEAD")
    run_git(clone, "checkout", "-q", "main")
    sha
  end

  # The same landing, as Ruby run inside the child between two prepare steps: another
  # session's merge arriving mid-release.
  def land_ruby(clone, file, content)
    <<~RUBY
      system("git", "-C", #{clone.inspect}, "checkout", "-q", "--detach", "origin/accepted")
      File.write(File.join(#{clone.inspect}, #{file.inspect}), #{content.inspect})
      system("git", "-C", #{clone.inspect}, "add", #{file.inspect})
      system("git", "-C", #{clone.inspect}, "commit", "-qm", "Merge reviewed #{file}")
      system("git", "-C", #{clone.inspect}, "push", "-q", "origin", "HEAD:refs/heads/accepted")
      system("git", "-C", #{clone.inspect}, "checkout", "-q", "main")
    RUBY
  end

  def remote_sha(dir, branch) = git_out(File.join(dir, "origin.git"), "rev-parse", branch)

  # Load bin/release in a child with the outside world stubbed: the CI guards on the
  # `accepted` head, the board, and `gh` (whose `pr merge` merges for real in a
  # scratch worktree, so the batch path lands a real merge commit).
  def run_seq(clone, dir, call)
    setup = <<~RUBY
      def repo_path(_repo) = #{clone.inspect}
      def refuse_red_accepted!(_targets) = nil
      def refuse_blind_accepted!(_targets) = nil
      def refuse_misfiled_changelog!(_targets) = {}
      def conductor(_ruby, read_only: false) = {}
      alias real_sh sh
      def sh(*a, **k)
        return real_sh(*a, **k) unless a[0] == "gh"

        $stdout.puts("GH-CALLED " + a.join(" "))
        return ["", true] if a[2] == "list"
        return ["https://gh/pr/batch", true] if a[2] == "create"
        if a[2] == "merge"
          $stdout.puts("GH-MERGE")
          ws = #{File.join(dir, 'gh-merge').inspect}
          system("git", "-C", #{clone.inspect}, "fetch", "-q", "origin")
          system("git", "-C", #{clone.inspect}, "worktree", "add", "-q", "--detach", ws, "origin/release")
          ok = system("git", "-C", ws, "merge", "-q", "--no-ff", "--no-edit", "origin/accepted") &&
               system("git", "-C", ws, "push", "-q", "origin", "HEAD:refs/heads/release")
          system("git", "-C", #{clone.inspect}, "worktree", "remove", "--force", ws)
          return ["", ok]
        end
        ["", false]
      end
    RUBY
    run_cli(["--yes"], setup: %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) + setup, call: call)
  end
end

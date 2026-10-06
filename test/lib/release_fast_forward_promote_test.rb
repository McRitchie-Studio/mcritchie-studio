# frozen_string_literal: true

# `bin/release prepare`'s `accepted → release` promote, driven against REAL git.
#
# The promote is a fast-forward ref push whenever `release` is contained in
# `accepted`, and the batch PR only when `release` has diverged. The commits prepare
# lands around it (the consumer lock bump, the archive and retro artifacts) go onto
# `accepted` first, so `release` never carries a commit `accepted` lacks. The proof
# that matters is the one the CI credit rests on: after a ship, `accepted`, `release`
# and `main` hold ONE commit id, so the verdict CI gave the `accepted` head is the
# verdict on the SHA production runs.
#
# The seams stubbed here are the ones that reach outside git: the CI guards on the
# `accepted` head, the RubyGems wait, `bundle lock`, the engine migration install,
# and `gh`. Every git command runs for real against a bare origin.
#
# Part of the bin/release CLI suite; the shared harness lives in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_fast_forward_promote_test.rb

require_relative "release_cli_harness"

class ReleaseFastForwardPromoteTest < ReleaseCliHarness
  GEM = "studio-engine"

  # [integration] The whole sequence on a contained `release`: promote, lock bump,
  # ship, archive artifact, next promote. No PR is opened at any step, and every
  # step leaves the three branches on one commit.
  def test_integration_a_release_sequence_leaves_one_sha_on_accepted_release_and_main
    with_ladder do |clone, dir|
      feature = land_on_accepted(clone, "feature.rb", "reviewed work")

      out = run_seq(clone, dir, %{
        promote_accepted_to_release!(["sibling"])
        puts("AFTER-PROMOTE")
        bump_consumer_locks_for_qa([{ "repo" => "sibling" }], { #{GEM.inspect} => "0.92.0" })
      })

      refute_includes out, "GH-CALLED", "a contained release is fast-forwarded, never promoted by a PR"
      assert_includes out, "fast-forward release → #{feature[0, 7]} in sibling"
      bumped = remote_sha(dir, "accepted")
      refute_equal feature, bumped, "the lock bump must land a commit on accepted"
      assert_equal feature, git_out(clone, "rev-parse", "#{bumped}^"), "the bump sits on the promoted head"
      assert_equal bumped, remote_sha(dir, "release"), "release fast-forwards to the bump accepted carries"
      assert_includes git_out(clone, "show", "#{bumped}:Gemfile.lock"), "#{GEM} (0.92.0)"
      assert_includes out, "onto origin/accepted, and fast-forwarded origin/release to it"

      # The ship: main takes the frozen release SHA by ref, and accepted's advance is a no-op.
      out = run_seq(clone, dir, %{push_frozen_main("sibling", #{bumped.inspect})})
      refute_includes out, "NOT advanced", "accepted already holds the shipped commit; nothing to reconcile"
      assert_equal [bumped] * 3, %w[accepted release main].map { |b| remote_sha(dir, b) },
                   "after a ship accepted, release and main share ONE commit id"

      # The archive artifact lands on accepted, so the next promote still fast-forwards.
      File.write(File.join(clone, "ledger.md"), "archived rows")
      out = run_seq(clone, dir, %{
        commit_artifact_to_accepted("sibling", #{File.join(clone, 'ledger.md').inspect}, "ledger: fixture")
        promote_accepted_to_release!(["sibling"])
      })
      assert_includes out, "committed ledger.md to accepted"
      refute_includes out, "GH-CALLED", "the artifact did not make release diverge"
      artifact = remote_sha(dir, "accepted")
      assert_equal bumped, git_out(clone, "rev-parse", "#{artifact}^"), "the artifact sits on the shipped commit"
      assert_equal artifact, remote_sha(dir, "release"), "the next promote fast-forwarded release to it"
      assert_equal bumped, remote_sha(dir, "main"), "main moves only at a ship"
    end
  end

  # [integration] The one-time divergence: `main` and `release` carry a commit
  # `accepted` lacks (Turf's "bump studio-engine 0.91.1 for QA", 7b351f2d). The first
  # promote takes the batch PR, then carries `accepted` onto its merge commit; the
  # promote after it is a fast-forward.
  def test_integration_a_diverged_release_takes_the_batch_pr_once_then_fast_forwards
    with_ladder do |clone, dir|
      run_git(clone, "checkout", "-q", "--detach", "origin/release")
      File.write(File.join(clone, "Gemfile.lock"), lock_text("0.91.1"))
      run_git(clone, "commit", "-qam", "bump studio-engine 0.91.1 for QA")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release", "HEAD:refs/heads/main")
      run_git(clone, "checkout", "-q", "main")
      run_git(clone, "pull", "-q", "--ff-only", "origin", "main")
      release_only = remote_sha(dir, "release")
      land_on_accepted(clone, "feature.rb", "reviewed work")

      out = run_seq(clone, dir, %{promote_accepted_to_release!(["sibling"])})

      assert_includes out, "GH-MERGE", "a diverged release is promoted by the batch PR"
      assert_includes out, "is NOT contained in `accepted`", "the output says why it took the batch PR"
      merge = remote_sha(dir, "release")
      assert_equal release_only, git_out(clone, "rev-parse", "#{merge}^1"), "the batch PR merged accepted into release"
      assert_equal merge, remote_sha(dir, "accepted"), "accepted is carried onto the merge commit"

      second = land_on_accepted(clone, "second.rb", "the next reviewed change")
      out = run_seq(clone, dir, %{promote_accepted_to_release!(["sibling"])})
      refute_includes out, "GH-CALLED", "after the carry, the next promote is a fast-forward"
      assert_equal second, remote_sha(dir, "release")
    end
  end

  private

  # A bare origin and a clone whose main, release and accepted all start on one seed
  # commit carrying a Gemfile that declares the gem. `.worktrees/` is ignored, as in
  # every real app, so the ship workspace is not dirt to the artifact commit.
  def with_ladder
    Dir.mktmpdir("release-ff-promote") do |dir|
      origin = File.join(dir, "origin.git")
      clone = File.join(dir, "repo")
      system("git", "init", "--bare", "-q", origin, out: File::NULL, err: File::NULL) || flunk("git init --bare failed")
      system("git", "clone", "-q", origin, clone, out: File::NULL, err: File::NULL) || flunk("git clone failed")
      run_git(clone, "symbolic-ref", "HEAD", "refs/heads/main")
      run_git(clone, "config", "user.email", "t@t.t")
      run_git(clone, "config", "user.name", "t")
      run_git(clone, "config", "commit.gpgsign", "false")
      File.write(File.join(clone, ".gitignore"), ".worktrees/\n")
      File.write(File.join(clone, "Gemfile"), %(gem "#{GEM}", "~> 0.90"\n))
      File.write(File.join(clone, "Gemfile.lock"), lock_text("0.90.0"))
      run_git(clone, "add", ".")
      run_git(clone, "commit", "-qm", "seed")
      run_git(clone, "push", "-q", "origin", "main", "main:release", "main:accepted")
      yield clone, dir
    end
  end

  def lock_text(version)
    "GEM\n  remote: https://rubygems.org/\n  specs:\n    #{GEM} (#{version})\n\n" \
      "DEPENDENCIES\n  #{GEM} (~> 0.90)\n"
  end

  # A reviewed change reaching `accepted` from the clone, the way review's merge lands.
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

  def remote_sha(dir, branch) = git_out(File.join(dir, "origin.git"), "rev-parse", branch)

  # Load bin/release in a child with the outside-world seams stubbed. `gh` is the
  # batch PR: `pr merge` performs the merge GitHub would, in a scratch worktree, so a
  # diverged promote lands a real merge commit on `release`.
  def run_seq(clone, dir, call)
    setup = <<~RUBY
      def repo_path(_repo) = #{clone.inspect}
      def refuse_red_accepted!(_targets) = nil
      def refuse_blind_accepted!(_targets) = nil
      def refuse_misfiled_changelog!(_targets) = {}
      def await_published_gems!(_published) = nil
      def install_engine_migrations!(*) = nil
      def bundle_lock(path, gem, attempts: 3, conservative: false, expect: nil)
        lock = File.join(path, "Gemfile.lock")
        File.write(lock, File.read(lock).sub(/^    \#{Regexp.escape(gem)} \\([^)]+\\)$/, "    \#{gem} (\#{expect})"))
      end
      alias real_sh sh
      def sh(*a, **k)
        return real_sh(*a, **k) unless a[0] == "gh"

        $stdout.puts("GH-CALLED " + a.join(" "))
        return ["", true] if a[2] == "list"
        return ["https://gh/pr/batch", true] if a[2] == "create"
        if a[2] == "merge"
          $stdout.puts("GH-MERGE")
          ws = #{File.join(dir, 'gh-merge').inspect}
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

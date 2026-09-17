# frozen_string_literal: true

# [unit] A commit made from a desk must name the SOUL that claimed it.
#
# THE DEFECT THIS EXISTS TO CATCH (measured 2026-09-06/07). Every commit a desk
# makes is authored by whatever git identity the CHECKOUT happens to carry, and
# that identity has nothing to do with the soul on the task board:
#
#   file:/Users/alex/.gitconfig                        -> Alex McRitchie    (the operator)
#   file:/Users/alex/projects/turf-monster/.git/config -> Steffon (Claude)  (a relic)
#
# turf-monster PR 573 was built by `shannon` and every commit on it reads
# "Steffon (Claude)". Commit 599c5327 on the same desk carries the identical
# mis-stamp, and a second desk shared by two builders produced six commits that
# all read "Steffon (Claude)" — the author field carried ZERO information about
# who wrote what.
#
# WHY NOT `git config user.name` IN THE DESK. A git worktree has NO config file
# of its own: `git rev-parse --git-dir` is .git/worktrees/<name>, but config
# resolves through --git-common-dir, so every desk of a repo SHARES
# .git/config. Writing an identity "into a desk" renames all 30 turf-monster
# desks at once. That is the defect, not the fix — and it is why
# test_two_desks_of_one_repo_do_not_share_an_identity below is the load-bearing
# test in this file rather than a nicety.
#
# TWO LAYERS, BOTH PROVED HERE. bin/ship's own commit is authored PER COMMIT,
# from the environment, which outranks every config file — the only grain that
# matches two souls taking turns at one desk. Every OTHER desk commit (the
# builder's mid-build commits, merge-forwards, rebases) never passes through
# bin/ship, so the desk is also stamped PER DESK, in its own config.worktree via
# extensions.worktreeConfig (turf-monster-git-identity-wrong, approved
# 2026-09-16). That is a DIFFERENT file from the shared .git/config, which is why
# the sibling-isolation property below still holds for the stamp. The "desk
# layer" section at the bottom proves it against real repos with the global
# config pinned to a scratch file.
#
# WHERE THE WIRING IS PROVED. Not here, and not by reading bin/ship's source: a
# source scan asserts a string, not a behaviour. test/lib/ship_test.rb runs the
# REAL bin/ship against a repo whose repo-level identity is `tester` and asserts
# the resulting commit's author out of git.
#
# WHAT THIS MUST NEVER DO. `devops.builders` is the AUTHOR SET bin/reviewer-select
# reads to keep a soul off their own PR, and its incompleteness is what makes
# that selector REFUSE — a loud, fail-closed refusal that is the system working.
# This code is READ-ONLY with respect to that set: it reads built_by and writes
# nothing back. A fix that made the field merely LOOK right would remove the
# refusal without restoring the property.

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

require_relative "../../lib/commit_identity"

class CommitIdentityTest < Minitest::Test
  # --- the defect, reproduced -------------------------------------------------

  def test_a_commit_carries_the_claiming_soul_and_not_the_repo_identity
    in_repo(poison: "Steffon (Claude)") do |root|
      touch(root, "a.txt")
      result = CommitIdentity.commit!(root, "work", devops(built_by: "carl"))

      # .ok, not the Struct — a Result object is always truthy, so asserting the
      # return value itself would pass on a failed commit.
      assert result.ok, "the commit must succeed"
      assert_equal "carl", result.soul

      # Read the identity OUT OF GIT — not out of a config file, and not out of
      # the return value. A test that asserts the script wrote a config line is
      # the inert-guard class this project keeps rediscovering.
      assert_equal "Carl", author_name(root)
      assert_equal "carl@mcritchie.studio", author_email(root),
                   "the email local-part is the exact soul slug, so git history " \
                   "joins directly to the board's author set"
    end
  end

  def test_the_soul_outranks_a_poisoned_repo_level_identity
    # turf-monster's ACTUAL measured state. The relic stays on disk; the commit
    # must be correct anyway, because a fix that requires cleaning 52 checkouts
    # first is a fix that does not land.
    in_repo(poison: "Steffon (Claude)") do |root|
      touch(root, "a.txt")
      CommitIdentity.commit!(root, "work", devops(built_by: "shannon"))

      assert_equal "shannon@mcritchie.studio", author_email(root)
      assert_equal "Steffon (Claude)", repo_config(root, "user.name"),
                   "the fix must not TOUCH the repo config — that write is the " \
                   "thing that renames every sibling desk"
    end
  end

  # --- the isolation property a config write would destroy --------------------

  def test_two_desks_of_one_repo_do_not_share_an_identity
    in_repo(poison: "Steffon (Claude)") do |root|
      desk_a = File.join(root, "..", "desk-a")
      desk_b = File.join(root, "..", "desk-b")
      git!(root, "worktree", "add", "-b", "feat/a", desk_a)
      git!(root, "worktree", "add", "-b", "feat/b", desk_b)

      # Prove the premise before relying on it: these two desks really do share
      # one config file, so an identity written "into" either would hit both.
      assert_equal git!(desk_a, "rev-parse", "--git-common-dir"),
                   git!(desk_b, "rev-parse", "--git-common-dir"),
                   "premise: worktrees of one repo share a config"

      touch(desk_a, "a.txt")
      CommitIdentity.commit!(desk_a, "carl's work", devops(built_by: "carl"))
      touch(desk_b, "b.txt")
      CommitIdentity.commit!(desk_b, "shannon's work", devops(built_by: "shannon"))

      assert_equal "carl@mcritchie.studio", author_email(desk_a)
      assert_equal "shannon@mcritchie.studio", author_email(desk_b),
                   "desk B must be unchanged by desk A's identity — the property " \
                   "`git config user.name` in a desk provably cannot hold"
    end
  end

  # --- the handoff grain ------------------------------------------------------

  def test_a_handoff_authors_under_the_current_builder_not_the_first
    # built_by is the CURRENT builder (Task#builder_roll_call: "built_by KEEPS
    # its meaning (the current builder) and builders ACCUMULATES"). The next
    # commit is written by whoever holds the desk now, so the author follows
    # built_by and never the head of the accumulated set.
    in_repo do |root|
      touch(root, "a.txt")
      CommitIdentity.commit!(root, "work", devops(built_by: "shannon", builders: %w[carl shannon]))

      assert_equal "shannon@mcritchie.studio", author_email(root)
    end
  end

  # --- fail honest, never fabricate ------------------------------------------

  def test_an_unattributed_task_is_not_given_a_fabricated_author
    in_repo(poison: "Steffon (Claude)") do |root|
      touch(root, "a.txt")
      CommitIdentity.commit!(root, "work", devops(built_by: nil))

      assert_equal "Steffon (Claude)", author_name(root),
                   "with no soul on record the commit stays on the machine " \
                   "identity — inventing one would launder an unattributed " \
                   "commit into a confident wrong answer"
    end
  end

  def test_a_value_that_is_not_a_soul_slug_is_refused
    # The exact shapes seen in the wild: a raw session UUID adopted by the
    # heartbeat, a capitalised name, and an underscored slug.
    ["8b12f485-ac04-4134-bbb6-ba9ac7e3c41d", "Steffon", "turf_monster", "", "  "].each do |bad|
      assert_empty CommitIdentity.env_for(devops(built_by: bad)),
                   "#{bad.inspect} is not a soul slug and must yield no identity"
    end
  end

  def test_a_hyphenated_soul_slug_is_accepted
    env = CommitIdentity.env_for(devops(built_by: "turf-monster"))

    assert_equal "Turf Monster", env["GIT_AUTHOR_NAME"]
    assert_equal "turf-monster@mcritchie.studio", env["GIT_AUTHOR_EMAIL"]
  end

  # --- the desk layer: stamp_worktree! against real repos -------------------
  #
  # THE DEFECT (measured 2026-09-16). bin/ship's env covers one commit. The
  # builder's hand commits in a turf-monster desk inherited the SHARED default in
  # .git/config — "Steffon (Claude)" — whoever the builder was: 131 non-merge
  # commits and 50 merges on origin/accepted since 2026-09-07. Every test below
  # commits with a PLAIN `git commit`, never through CommitIdentity.commit!, because
  # the hand commit is the path under test.

  def test_a_hand_commit_in_a_stamped_desk_carries_the_claiming_soul
    in_repo(poison: "Steffon (Claude)") do |root|
      desk = add_desk(root, "feat/a")

      result = CommitIdentity.stamp_worktree!(desk, "jasper")

      assert result.ok, "the stamp must land: #{result.message}"
      hand_commit(desk)
      assert_equal "Jasper <jasper@mcritchie.studio>", git!(desk, "log", "-1", "--format=%an <%ae>")
      assert_equal "Jasper <jasper@mcritchie.studio>", git!(desk, "log", "-1", "--format=%cn <%ce>"),
                   "the committer line must name the soul too, or a rebase keeps the relic in %cn"
      assert_equal CommitIdentity.env_for("built_by" => "jasper")["GIT_AUTHOR_NAME"], result.name,
                   "the desk stamp and bin/ship's commit must spell a soul the SAME way"
    end
  end

  def test_stamping_one_desk_leaves_its_sibling_and_the_primary_alone
    in_repo(poison: "Steffon (Claude)") do |root|
      desk_a = add_desk(root, "feat/a")
      desk_b = add_desk(root, "feat/b")
      primary_before = ident(root)
      sibling_before = ident(desk_b)

      assert CommitIdentity.stamp_worktree!(desk_a, "carl").ok

      assert_equal primary_before, ident(root), "the primary must resolve exactly as before"
      assert_equal sibling_before, ident(desk_b), "an unstamped sibling must resolve exactly as before"
      hand_commit(desk_b)
      assert_equal "Steffon (Claude)", author_name(desk_b)
      refute_equal "Carl", repo_config(root, "user.name"),
                   "the stamp must never land in the SHARED config — that write renames every desk"
    end
  end

  def test_the_extension_switch_is_the_only_shared_write
    in_repo do |root|
      desk = add_desk(root, "feat/a")
      shared_before = shared_config_lines(root)

      result = CommitIdentity.stamp_worktree!(desk, "shannon")

      assert result.ok
      assert result.enabled, "the first stamp in a repo switches the extension on and says so"
      assert_equal ["extensions.worktreeconfig=true"], shared_config_lines(root) - shared_before,
                   "exactly one key may be added to .git/config, and it is not an identity"
      refute CommitIdentity.stamp_worktree!(desk, "shannon").enabled,
             "a re-stamp must not claim to have switched on an extension that was already on"
    end
  end

  def test_the_stamp_never_writes_the_global_file
    in_repo do |root|
      desk = add_desk(root, "feat/a")
      global = ENV.fetch("GIT_CONFIG_GLOBAL")
      File.write(global, "[user]\n\tname = Operator\n\temail = operator@example.com\n")
      before = File.binread(global)

      assert CommitIdentity.stamp_worktree!(desk, "avi").ok

      assert_equal before, File.binread(global), "the global file must be byte-for-byte untouched"
      assert_equal "Avi <avi@mcritchie.studio>", ident(desk),
                   "the desk stamp outranks the global identity it leaves in place"
    end
  end

  def test_a_re_stamp_repoints_the_desk_for_a_handoff
    in_repo do |root|
      desk = add_desk(root, "feat/a")
      CommitIdentity.stamp_worktree!(desk, "carl")

      CommitIdentity.stamp_worktree!(desk, "turf-monster")

      hand_commit(desk)
      assert_equal "Turf Monster <turf-monster@mcritchie.studio>", git!(desk, "log", "-1", "--format=%an <%ae>")
    end
  end

  def test_a_primary_checkout_is_refused_and_left_untouched
    in_repo do |root|
      shared_before = shared_config_lines(root)

      result = CommitIdentity.stamp_worktree!(root, "carl")

      refute result.ok
      assert_equal :primary, result.refused
      assert_equal shared_before, shared_config_lines(root),
                   "a refused stamp must not even switch the extension on"
      assert_equal "Alex McRitchie <amcritchie@gmail.com>", ident(root)
    end
  end

  def test_a_value_that_is_not_a_soul_is_refused_before_any_git_call
    calls = []
    spy = ->(*args) { calls << args; ["", true] }

    ["Steffon", "turf_monster", "8b12f485-ac04-4134-bbb6-ba9ac7e3c41d", ""].each do |bad|
      result = CommitIdentity.stamp_worktree!("/nowhere", bad, git: spy)
      refute result.ok
      assert_equal :not_a_soul, result.refused
    end
    assert_empty calls, "a refused soul must not reach git at all"
  end

  def test_a_repo_whose_shared_config_the_extension_would_change_is_refused
    # Git's documented hazard: core.worktree (or core.bare=true) in the shared config
    # must move before extensions.worktreeConfig is switched on. Driven with a runner
    # because a real repo carrying core.worktree re-roots every command run in it.
    writes = []
    answers = {
      %w[rev-parse --path-format=absolute --git-dir] => ["/r/.git/worktrees/a\n", true],
      %w[rev-parse --path-format=absolute --git-common-dir] => ["/r/.git\n", true],
      %w[config --local --get extensions.worktreeConfig] => ["", false],
      %w[config --local --get core.bare] => ["false\n", true],
      %w[config --local --get core.worktree] => ["/elsewhere\n", true]
    }
    runner = lambda do |_dir, *args|
      answers.fetch(args) { writes << args; ["", true] }
    end

    result = CommitIdentity.stamp_worktree!("/r/.worktrees/a", "carl", git: runner)

    assert_equal :unsafe_repo, result.refused
    assert_empty writes, "nothing may be written to a repo the extension would re-root"
  end

  def test_a_dormant_config_worktree_elsewhere_blocks_the_switch
    # With the extension OFF git ignores config.worktree files. Switching it on for
    # one desk would silently activate a leftover file in another desk — changing a
    # checkout nobody asked to change. Measured: no repo here carries one today.
    in_repo(poison: "Steffon (Claude)") do |root|
      desk = add_desk(root, "feat/a")
      other = add_desk(root, "feat/b")
      dormant = File.join(git!(other, "rev-parse", "--path-format=absolute", "--git-dir"), "config.worktree")
      File.write(dormant, "[user]\n\tname = Leftover\n")
      before = ident(other)

      result = CommitIdentity.stamp_worktree!(desk, "carl")

      assert_equal :unsafe_repo, result.refused
      assert_includes result.message, dormant
      assert_nil repo_config_or_nil(root, "extensions.worktreeConfig"), "the switch must stay off"
      assert_equal before, ident(other), "the other desk must resolve exactly as before"
    end
  end

  def test_an_unstamped_desk_with_no_identity_anywhere_refuses_the_commit_loudly
    # The machine-independent half of "unstamped is loud": with no global identity,
    # no repo identity and git's hostname guess turned off, the only thing that can
    # author a desk commit is the stamp. (On this Mac ~/.gitconfig DOES carry an
    # identity, so there an unstamped commit falls through to it instead — see
    # lib/commit_identity.rb, "WHY NOT MAKE THE UNSTAMPED COMMIT FAIL".)
    in_repo(identity: false) do |root|
      stamped = add_desk(root, "feat/a")
      unstamped = add_desk(root, "feat/b")
      assert CommitIdentity.stamp_worktree!(stamped, "carl").ok

      _out, err, status = Open3.capture3("git", "-C", unstamped, "-c", "user.useConfigOnly=true",
                                         "commit", "--allow-empty", "-m", "no one")
      refute status.success?, "an unstamped desk with no identity anywhere must not commit"
      assert_match(/Please tell me who you are/, err)

      _out, err, status = Open3.capture3("git", "-C", stamped, "-c", "user.useConfigOnly=true",
                                         "commit", "--allow-empty", "-m", "carl")
      assert status.success?, "the stamped sibling must commit: #{err}"
      assert_equal "Carl", author_name(stamped)
    end
  end

  def test_worktree_identity_reads_nil_for_an_identity_from_any_other_scope
    in_repo(poison: "Steffon (Claude)") do |root|
      desk = add_desk(root, "feat/a")

      assert_nil CommitIdentity.worktree_identity(desk),
                 "an identity inherited from the SHARED config is not a stamp"
      CommitIdentity.stamp_worktree!(desk, "carl")
      assert_equal ["Carl", "carl@mcritchie.studio"], CommitIdentity.worktree_identity(desk)
    end
  end

  private

  def add_desk(root, branch)
    desk = File.join(File.dirname(root), branch.tr("/", "-"))
    if git_unborn?(root)
      git!(root, "-c", "user.name=Seed", "-c", "user.email=seed@example.com",
           "commit", "--allow-empty", "-q", "-m", "base")
    end
    git!(root, "worktree", "add", "-q", "-b", branch, desk)
    desk
  end

  def git_unborn?(root)
    _out, _err, status = Open3.capture3("git", "-C", root, "rev-parse", "--verify", "-q", "HEAD")
    !status.success?
  end

  def hand_commit(dir)
    git!(dir, "commit", "--allow-empty", "-q", "-m", "a hand commit, no bin/ship")
  end

  def ident(dir) = git!(dir, "var", "GIT_AUTHOR_IDENT").sub(/\s+\d+\s+[-+]\d{4}\z/, "")

  def shared_config_lines(root) = git!(root, "config", "--local", "--list").lines.map(&:strip)

  def devops(built_by: :unset, builders: nil)
    d = {}
    d["built_by"] = built_by unless built_by == :unset
    d["builders"] = builders if builders
    d
  end

  # A real repo with a real (poisoned) repo-level identity, isolated from the
  # machine's global config so the test measures only what it set up.
  def in_repo(poison: nil, identity: true)
    Dir.mktmpdir("commit-identity") do |tmp|
      home = File.join(tmp, "home")
      FileUtils.mkdir_p(home)
      root = File.join(tmp, "repo")
      FileUtils.mkdir_p(root)

      with_env("HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"),
               "GIT_CONFIG_GLOBAL" => File.join(home, ".gitconfig"),
               "GIT_CONFIG_SYSTEM" => File.join(home, ".gitconfig.system"),
               "GIT_AUTHOR_NAME" => nil, "GIT_AUTHOR_EMAIL" => nil,
               "GIT_COMMITTER_NAME" => nil, "GIT_COMMITTER_EMAIL" => nil) do
        git!(root, "init", "-q", "-b", "main")
        # The machine identity every desk inherits when nothing else is set.
        # identity: false leaves the repo with NO identity at any scope (the global
        # file above does not exist), for the tests about what supplies one.
        if identity
          git!(root, "config", "user.name", poison || "Alex McRitchie")
          git!(root, "config", "user.email", "amcritchie@gmail.com")
        end
        yield root
      end
    end
  end

  def with_env(pairs)
    old = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def touch(root, name)
    File.write(File.join(root, name), "#{name}\n#{rand}")
  end

  def git!(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def author_name(root) = git!(root, "log", "-1", "--format=%an")
  def author_email(root) = git!(root, "log", "-1", "--format=%ae")
  def repo_config(root, key) = git!(root, "config", "--local", "--get", key)

  def repo_config_or_nil(root, key)
    out, _err, status = Open3.capture3("git", "-C", root, "config", "--local", "--get", key)
    status.success? ? out.strip : nil
  end
end

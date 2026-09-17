# frozen_string_literal: true

# CommitIdentity — the git author a desk's commit carries.
#
# THE DEFECT (measured 2026-09-06/07). Nothing in this ecosystem ever set a git
# identity, so every commit an agent made was authored by whatever the checkout
# happened to carry. Measured directly with `git config --show-origin`:
#
#   file:/Users/alex/.gitconfig                        -> Alex McRitchie    (the operator)
#   file:/Users/alex/projects/turf-monster/.git/config -> Steffon (Claude)  (a relic)
#
# turf-monster PR 573 was built by `shannon`; its single commit, and 599c5327
# on the same desk, read "Steffon (Claude)". A desk shared by two souls
# produced six commits that ALL read "Steffon (Claude)" — the author field
# carried zero information about who wrote what, and the only thing that
# separated the two builders was an incidental `Claude-Session:` trailer.
#
# The cost is archaeological and permanent: this project dates changes by commit
# routinely (one review dated a constant across 105 installed engine trees to
# establish a version floor), and a history that names the wrong soul quietly
# corrupts that method.
#
# ── TWO LAYERS: PER COMMIT FOR bin/ship, PER DESK FOR EVERYTHING ELSE ───────
#
# A plain `git config user.name` has no per-desk home. `git rev-parse --git-dir`
# is .git/worktrees/<name>, but config resolves through --git-common-dir, so every
# desk of a repo SHARES .git/config. `git config user.name <soul>` run "in a
# desk" therefore renames all 30 turf-monster desks at once. That is how the
# relic above got there in the first place — the obvious fix IS the defect.
#
# LAYER 1 — PER COMMIT (env_for / commit!). The environment outranks every config
# file and matches the grain of a desk two souls take turns at, so bin/ship's
# commit is authored from `built_by` at the moment it is made.
#
# LAYER 2 — PER DESK (stamp_worktree!). Layer 1 covers exactly ONE commit: the one
# bin/ship makes. Everything else a desk commits never passes through it — the
# builder's own mid-build commits, a merge-forward, a rebase's committer line.
# Those inherited whatever the checkout carried. Measured 2026-09-16 on
# turf-monster `origin/accepted` since layer 1 landed (2026-09-07): 131 non-merge
# commits and 50 merges read "Steffon (Claude)" (the shared default, reached by
# hand commits) while 14 read "Steffon <steffon@mcritchie.studio>" (layer 1). Two
# spellings of one soul, two mechanisms — and on 2026-09-15 a reviewer read the
# first one as authorship and reasoned wrongly from it.
#
# `extensions.worktreeConfig` + `git config --worktree` gives each desk its own
# config file (.git/worktrees/<name>/config.worktree), which outranks the shared
# one. It was once rejected here on two grounds; both were re-measured when Mr.
# McRitchie approved the desk stamp (2026-09-16):
#
#   * COST. "It re-resolves config for every read" — measured on git 2.50: 400
#     `git config --get` calls per round, extension off vs on, alternating rounds:
#     14.03/12.39 ms and 11.15/10.13 ms. The difference is inside process-spawn
#     noise, in both directions.
#   * GRAIN. Still true that a desk holds one identity. That is why layer 1 stays:
#     the env still wins for the ship commit, and the desk stamp only names the
#     soul who CLAIMED the desk for the commits nothing else attributes. A
#     re-claim through `bin/task begin --steal` re-stamps it.
#
# The shared default is gone too (removed from turf-monster's .git/config the same
# day), so an unstamped desk no longer wears a soul's name.
#
# ── WHICH SOUL ──────────────────────────────────────────────────────────────
#
# `devops.built_by`, which Task#builder_roll_call defines as THE CURRENT BUILDER
# ("built_by KEEPS its meaning (the current builder) and builders ACCUMULATES").
# That is exactly the soul who writes the next commit, and it already repoints on
# an explicit `--actor`/`--agent`, so a handoff or a `--steal` authors subsequent
# commits under whoever holds the desk now, with no extra machinery.
#
# NOT `devops.builders`. That is the accumulated AUTHOR SET `bin/reviewer-select`
# reads to keep a soul off their own PR, and an incomplete set is what makes that
# selector REFUSE — a loud, fail-closed refusal that is the system working. This
# module is READ-ONLY with respect to the author set: it reads built_by and
# writes nothing back to the board, so it cannot make the exclusion wrong and
# cannot remove the refusal.
#
# ── WHEN THE SOUL IS UNKNOWN ────────────────────────────────────────────────
#
# No identity is set and the commit falls through to the machine's own. An
# unattributed commit that SAYS it is unattributed is recoverable; one laundered
# under a fabricated soul is a confident wrong answer, which is the failure this
# whole ticket is about.
#
# WHY NOT MAKE THE UNSTAMPED COMMIT FAIL. The machine carries a global identity
# (Alex McRitchie, in ~/.gitconfig, which no agent may write), so an unstamped
# commit does not fail on its own. The only config-level way to force git's
# "Please tell me who you are" is an EMPTY user.name, and that was measured and
# rejected (2026-09-16, git 2.50): it also breaks `git stash`, and the error git
# prints tells the reader to run `git config --global user.name` (a write to the
# operator's file) or, "omitting --global", to set the SHARED repo default — the
# exact defect above. A failure whose printed remedy is the forbidden write is a
# trap, not a signal. So the unstamped case is made loud where the remedy CAN be
# printed correctly: `bin/agent-worktree new` and `bin/task begin` announce an
# UNSTAMPED desk and name the stamp command.
#
# Plain Ruby (no Rails) so the standalone bin/ship CLI can require_relative it.
require "open3"

module CommitIdentity
  # The soul-slug shape — a deliberate mirror of bin/task's SOUL_SLUG, which is
  # itself a mirror of Task::SOUL_SLUG. Shape only: like bin/task, this holds no
  # roster. It does not need one — `built_by` is server-owned and only ever
  # stamped from a value the model already roster-checked with Task.soul?, so the
  # shape check here is a guard against the NON-soul values seen in the wild (a
  # raw session UUID adopted by the heartbeat, a capitalised "Steffon", an
  # underscored "turf_monster"), not a second authority on who exists.
  SOUL_SLUG = /\A[a-z]+(?:-[a-z]+)*\z/

  # The soul mailbox convention already used across the ecosystem
  # (carl@, shannon@, steffon@ …). The local part IS the slug, so `git log
  # --format=%ae` joins directly to the board's author set with no mapping table.
  MAIL_DOMAIN = "mcritchie.studio"

  # `failed` names WHICH git call failed (:add or :commit) so the caller can say
  # so; nil on success.
  Result = Struct.new(:ok, :soul, :name, :email, :failed, keyword_init: true)

  # The GIT_AUTHOR_*/GIT_COMMITTER_* pairs for a task's devops slice, or {} when
  # no soul is on record. Pure — no git, no clock, no environment.
  #
  # Committer is set alongside author deliberately. In this system the soul both
  # writes the change and runs `bin/ship`, so there is no second party to name;
  # leaving the committer unset would keep the relic ("Steffon (Claude)") on
  # `git log --format=%cn` and leave half the provenance still lying.
  def self.env_for(devops)
    soul = soul_of(devops)
    return {} unless soul

    name = display_name(soul)
    email = "#{soul}@#{MAIL_DOMAIN}"
    {
      "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email,
      "GIT_COMMITTER_NAME" => name, "GIT_COMMITTER_EMAIL" => email
    }
  end

  # The current builder's slug, or nil when the record names no soul.
  def self.soul_of(devops)
    value = (devops || {})["built_by"].to_s.strip
    value.match?(SOUL_SLUG) ? value : nil
  end

  # "carl" => "Carl", "turf-monster" => "Turf Monster".
  def self.display_name(soul)
    soul.split("-").map(&:capitalize).join(" ")
  end

  # Stage everything and commit it under the claiming soul.
  #
  # THE ONLY COMMIT PATH bin/ship has. Keeping add+commit together here — rather
  # than exporting just the env and leaving the commit in ship — is what makes
  # the tested code and the shipped code the same code: a second commit site
  # would silently reopen the defect, and a test that scanned ship's source for
  # a string would not notice.
  def self.commit!(root, message, devops, runner: method(:system))
    env = env_for(devops)
    soul = soul_of(devops)
    added = runner.call({}, "git", "-C", root, "add", "-A", out: File::NULL, err: File::NULL)
    return Result.new(ok: false, soul: soul, failed: :add) unless added

    ok = runner.call(env, "git", "-C", root, "commit", "-m", message,
                     out: File::NULL, err: File::NULL)
    Result.new(ok: ok, soul: soul, name: env["GIT_AUTHOR_NAME"],
               email: env["GIT_AUTHOR_EMAIL"], failed: ok ? nil : :commit)
  end

  # ── LAYER 2: the desk stamp ─────────────────────────────────────────────────

  # `refused` names WHY nothing was written (:not_a_soul, :not_a_checkout,
  # :primary, :unsafe_repo); `failed` names the git write that did not land
  # (:extension, :write, :read_back). Both nil on success. `enabled` is true only
  # when THIS call switched extensions.worktreeConfig on for the repo.
  StampResult = Struct.new(:ok, :soul, :name, :email, :enabled, :refused, :failed, :message,
                           keyword_init: true)

  # The default git runner: [stdout, success?]. Injectable so the refusals can be
  # proven without a repo; the behaviour tests use the real one.
  def self.capture_git(dir, *args)
    out, _err, status = Open3.capture3("git", "-C", dir.to_s, *args)
    [out, status.success?]
  end

  # Stamp one desk with its claiming soul, in that desk's OWN config file.
  #
  # Writes exactly three values and no others:
  #
  #   .git/config                          extensions.worktreeConfig = true
  #                                        (once per repo; a switch, not an identity)
  #   .git/worktrees/<desk>/config.worktree  user.name  = Carl
  #                                          user.email = carl@mcritchie.studio
  #
  # It never writes a user.* key into the shared .git/config (the defect) and never
  # touches the global file (git config --worktree cannot reach it).
  #
  # REFUSES A PRIMARY. A primary checkout is a loading dock: release artifact
  # commits and the operator's own commits land there. Stamping it would give all
  # of them a soul's name, which is the shared default again under another path.
  #
  # REFUSES A REPO THE EXTENSION WOULD CHANGE. Git's own documentation for
  # extensions.worktreeConfig: `core.bare` (when true) and `core.worktree` in the
  # shared config must be moved to the main worktree's config.worktree before the
  # extension is switched on, or every worktree starts reading them. Every repo in
  # this ecosystem carries `core.bare = false` and no core.worktree (measured
  # 2026-09-16), so this never fires here — it exists so a repo that ever does
  # carry one is left alone and says so, rather than being silently re-rooted.
  #
  # Idempotent: re-stamping a desk overwrites its two keys, which is how a handoff
  # (`bin/task begin <slug> --agent <soul> --steal`) re-points it.
  def self.stamp_worktree!(dir, soul, git: method(:capture_git))
    soul = soul.to_s.strip
    unless soul.match?(SOUL_SLUG)
      return StampResult.new(ok: false, refused: :not_a_soul,
                             message: "#{soul.inspect} is not a soul slug (lowercase, single hyphens) — nothing stamped")
    end

    name = display_name(soul)
    email = "#{soul}@#{MAIL_DOMAIN}"
    base = { soul: soul, name: name, email: email }

    git_dir, git_ok = git.call(dir, "rev-parse", "--path-format=absolute", "--git-dir")
    common, common_ok = git.call(dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
    unless git_ok && common_ok
      return StampResult.new(ok: false, refused: :not_a_checkout, **base,
                             message: "#{dir} is not a git checkout — nothing stamped")
    end
    if same_path?(git_dir, common)
      return StampResult.new(ok: false, refused: :primary, **base,
                             message: "#{dir} is a PRIMARY checkout, not a desk — a stamp there would name a soul on " \
                                      "every commit made in it (release artifacts, the operator's own). Nothing stamped")
    end

    enabled = false
    switch, = git.call(dir, "config", "--local", "--get", "extensions.worktreeConfig")
    unless switch.to_s.strip.casecmp?("true")
      bare, = git.call(dir, "config", "--local", "--get", "core.bare")
      _worktree, has_worktree = git.call(dir, "config", "--local", "--get", "core.worktree")
      if bare.to_s.strip.casecmp?("true") || has_worktree
        return StampResult.new(ok: false, refused: :unsafe_repo, **base,
                               message: "the repo's shared config carries core.bare=true or core.worktree, which " \
                                        "extensions.worktreeConfig would expose to every worktree — nothing stamped")
      end
      # A config.worktree that already exists while the switch is OFF is dormant:
      # git ignores it today and would start honouring it the instant the switch
      # flips — changing some OTHER checkout's config behind its owner's back. None
      # existed in any repo here on 2026-09-16; this keeps "switching the extension
      # on changes nothing for an existing desk" a checked property, not a memory.
      dormant = Dir.glob([File.join(common.strip, "config.worktree"),
                          File.join(common.strip, "worktrees", "*", "config.worktree")])
      unless dormant.empty?
        return StampResult.new(ok: false, refused: :unsafe_repo, **base,
                               message: "extensions.worktreeConfig is off but #{dormant.join(", ")} already " \
                                        "exist(s); switching it on would activate them — nothing stamped")
      end
      _, on = git.call(dir, "config", "--local", "extensions.worktreeConfig", "true")
      return StampResult.new(ok: false, failed: :extension, **base, message: "could not enable extensions.worktreeConfig") unless on

      enabled = true
    end

    _, named = git.call(dir, "config", "--worktree", "user.name", name)
    _, mailed = git.call(dir, "config", "--worktree", "user.email", email)
    unless named && mailed
      return StampResult.new(ok: false, failed: :write, enabled: enabled, **base,
                             message: "git config --worktree did not write user.name/user.email")
    end

    # READ BACK through git's own resolution, the way a commit will read it — a
    # write that git then outranks (or ignores) is not a stamp.
    ok = worktree_identity(dir, git: git) == [name, email]
    StampResult.new(ok: ok, enabled: enabled, failed: ok ? nil : :read_back, **base,
                    message: ok ? nil : "wrote the desk identity, but git does not resolve it from the worktree scope")
  end

  # The identity a desk's OWN config file supplies, as [name, email] — or nil when
  # either half resolves from anywhere else (the shared repo config, the global
  # file, an unset key). Read through `--show-scope`, so a stamp that git
  # outranks or ignores reads as nil, never as stamped.
  def self.worktree_identity(dir, git: method(:capture_git))
    pairs = %w[user.name user.email].map do |key|
      out, ok = git.call(dir, "config", "--show-scope", "--get", key)
      scope, value = out.to_s.strip.split("\t", 2)
      ok && scope == "worktree" ? value : nil
    end
    pairs.all? ? pairs : nil
  end

  def self.same_path?(left, right)
    File.expand_path(left.to_s.strip) == File.expand_path(right.to_s.strip) ||
      (File.exist?(left.to_s.strip) && File.exist?(right.to_s.strip) &&
       File.realpath(left.to_s.strip) == File.realpath(right.to_s.strip))
  end
end

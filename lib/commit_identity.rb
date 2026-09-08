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
# ── WHY THIS IS PER-COMMIT AND NOT PER-DESK ─────────────────────────────────
#
# A git worktree has NO config file of its own. `git rev-parse --git-dir` is
# .git/worktrees/<name>, but config resolves through --git-common-dir, so every
# desk of a repo SHARES .git/config. `git config user.name <soul>` run "in a
# desk" therefore renames all 30 turf-monster desks at once. That is how the
# relic above got there in the first place — the obvious fix IS the defect.
#
# `extensions.worktreeConfig` + `git config --worktree` would give a desk its own
# identity, and was rejected on two grounds: it re-resolves config for every read
# in the repo (52 live worktrees across the two repos) to attribute a commit, and
# it still buys the WRONG GRAIN — a desk holds one identity, while the measured
# reality is two souls on one desk.
#
# The environment outranks every config file, costs no config write, and matches
# the grain of the thing being attributed. So the author is set per COMMIT.
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
# Plain Ruby (no Rails) so the standalone bin/ship CLI can require_relative it.
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
end

# frozen_string_literal: true

require "time"
require "json"

# DESK ACTIVITY — the liveness signal that survives the status-line problem.
#
# The build claim's lease (lib/claim_lease.rb) is renewed by bin/statusline, which
# paints every ~5s whether or not an agent is doing anything. So the lease attests
# "a terminal is open", and an open terminal is not a worker: on 2026-08-13 a
# claim renewed itself 16:05:16Z → 16:06:46Z while its holder produced nothing the
# board could see for ~40 minutes, and three agents stalled behind it.
#
# THE OBVIOUS FIX IS WRONG, and this module exists because of that. "Renew only on
# durable task writes" reads as correct and is not: the very session that looked
# dead on the board WAS working — it wrote e2e/onboarding_tokens_handoff.spec.js at
# 09:40:58 and test/integration/onboarding_chain_test.rb at 09:41:37, both bespoke
# to the race it was repairing. A board-keyed liveness rule would have declared
# that session dead WHILE IT WAS EDITING CODE, licensing a steal against a live
# worker — a worse error than the one it fixes, because a lingering lease costs
# minutes of waiting while a wrongful steal costs the work itself.
#
# The signal that actually tracked the truth was the FILESYSTEM. An agent that is
# working writes files into its desk; an agent that has walked away does not. So
# this module answers questions about a desk from the filesystem alone:
#
#   DeskActivity.touched_since?(root, cutoff) → true | false | nil   (is it being worked?)
#   DeskActivity.age_seconds(root)            → Float | nil          (how old is it?)
#
# and in both, the `nil` answer is load-bearing. `nil` means WE COULD NOT TELL, and
# every consumer must treat it as "assume the holder is alive". Absence of evidence is
# never evidence of absence — that is the rule this whole family of bugs keeps
# breaking (see the phantom shift lease and the phantom BUILD claim before it).
#
# Age joined the module on 2026-08-13, when `cleanup --reclaim` destroyed a live desk
# a builder had just created: a brand-new worktree is git-identical to a merged one
# (clean, nothing ahead of base), so the git test that guards reclaim passes on it
# VACUOUSLY. See age_seconds for why it is a separate channel from the mtimes.
module DeskActivity
  # Directories whose mtimes are MACHINE churn, not agent work. Pruning these is
  # the difference between a liveness signal and a second status line.
  #
  #   .git       — bin/statusline itself runs git on every paint, and git touches
  #                the index. Counting it would make the status line renew the
  #                lease again, one indirection further out. This one is the whole
  #                bug wearing a different hat.
  #   log, tmp   — a running `rails s`/`sidekiq` in the desk writes here forever
  #                after its agent has gone home. A server is not a worker.
  #   node_modules, vendor, .bundle — installers touch thousands of files at once.
  #   public/assets, public/packs, coverage, test-results, playwright-report,
  #   storage    — build and test OUTPUT, written by tooling rather than authored.
  #
  # Everything surviving this list is something a human or an agent typed.
  PRUNED_DIRS = %w[
    .git node_modules tmp log storage coverage vendor .bundle .yarn .venv
    public/assets public/packs test-results playwright-report .playwright
  ].freeze

  # A hard ceiling on entries examined per walk. A desk that somehow exceeds it
  # answers `nil` (unknown), NOT `false` — an unfinished search must never be
  # reported as a quiet desk, because `false` is the answer that frees a claim.
  # The budget bounds a heartbeat that runs every ~45s on the operator's laptop;
  # a pruned Rails worktree sits around 3-6k entries, so this is roughly 4x
  # headroom, not a limit real desks meet.
  WALK_BUDGET = 25_000

  # True when ANY authored file under `root` was modified at or after `cutoff`.
  # False when the walk completed and found none. Nil when the question could not
  # be answered — no root, an unreadable root, or a walk that ran out of budget.
  #
  # Short-circuits on the FIRST fresh file, so the common case (an agent that is
  # working) costs a handful of stats. The full walk only happens on a desk that
  # is genuinely quiet, which is the case we can afford to spend on.
  def self.touched_since?(root, cutoff)
    root = root.to_s
    return nil if root.empty?
    return nil unless File.directory?(root)

    examined = 0
    stack = [root]
    until stack.empty?
      dir = stack.pop
      children =
        begin
          Dir.each_child(dir).to_a
        rescue SystemCallError
          next # an unreadable subtree is skipped, not fatal — the walk continues
        end

      children.each do |name|
        path = File.join(dir, name)
        next if pruned?(path, root)

        examined += 1
        return nil if examined > WALK_BUDGET

        stat =
          begin
            File.lstat(path)
          rescue SystemCallError
            next # raced away mid-walk (a cert cleaning up); not evidence either way
          end

        # Symlinks are followed for neither their target nor their own mtime: a
        # desk's symlinks point at shared caches, whose churn is not this desk's
        # work. lstat above is what keeps the walk inside the desk.
        if stat.directory?
          stack << path
        elsif stat.file? && stat.mtime >= cutoff
          return true
        end
      end
    end

    false
  end

  # Seconds since this desk was CREATED, or nil when we cannot tell.
  #
  # WHY AGE IS A CHANNEL AT ALL, next to the mtimes above. `git worktree add` writes
  # every file of the checkout, so a desk born minutes ago normally answers
  # `touched_since? => true` on its own creation and needs no second signal. Age is the
  # FLOOR under that answer: it needs no walk, no prune list, and no assumption about
  # how the checkout got populated — a half-allocated desk (worktree created, stack and
  # bind-task failed, which the Redis band ceiling produced repeatedly on 2026-08-13)
  # may have almost nothing in it, and this still dates it.
  #
  # THE BIRTHDAY IS THE `.git` FILE. In a worktree, `.git` is a regular FILE holding
  # `gitdir: …`, written once by `git worktree add` and not rewritten in ordinary use.
  # `git worktree repair`/`move` do rewrite it, which makes the desk read YOUNGER than
  # it is — the direction that KEEPS a desk, so the error is the safe one. (`.git` is
  # on PRUNED_DIRS above for the mtime walk, and rightly so: bin/statusline runs git on
  # every paint and touches the index. That prune is about the `.git` DIRECTORY's
  # contents churning; this reads the pointer FILE's own mtime, which the status line
  # never writes.)
  #
  # A `.git` DIRECTORY means a primary checkout rather than a worktree desk, and its
  # mtime is not a birthday at all — that answers nil (unknown), never a guess.
  def self.age_seconds(root, now: Time.now)
    root = root.to_s
    return nil if root.empty?

    stat =
      begin
        File.lstat(File.join(root, ".git"))
      rescue SystemCallError
        return nil
      end
    return nil unless stat.file?

    age = now - stat.mtime
    age.negative? ? 0.0 : age # a clock skew reads as newborn, which KEEPS the desk
  end

  # Path-prefix prune, matched on the path RELATIVE to the desk root — so a desk
  # named ".../tmp-fix-something" is not pruned for containing "tmp", and an app's
  # own `app/models/log_entry.rb` is not pruned for starting with "log".
  def self.pruned?(path, root)
    relative = path.delete_prefix(root).delete_prefix(File::SEPARATOR)
    PRUNED_DIRS.any? { |dir| relative == dir || relative.start_with?("#{dir}#{File::SEPARATOR}") }
  end

  # Resolve the desk a claim on `slug` should be judged by, and REFUSE to judge it
  # by any other. `root` is a candidate directory (bin/statusline passes its cwd);
  # it counts only when it carries an .agent-context.json bound to this very task.
  #
  # Without this check the heartbeat would read whichever checkout it happened to
  # be launched from. The primary checkout is the dangerous one: several agents
  # write to it all day, so its mtimes are ALWAYS fresh, and a claim judged there
  # would renew forever — the status-line bug rebuilt out of file mtimes. A desk
  # we cannot bind to the task is no desk at all, and returns nil (unknown).
  def self.desk_root(root, slug)
    root = root.to_s
    slug = slug.to_s
    return nil if root.empty? || slug.empty?

    context = File.join(root, ".agent-context.json")
    return nil unless File.file?(context)

    payload =
      begin
        JSON.parse(File.read(context))
      rescue StandardError
        return nil
      end

    bound = [payload["task_slug"], payload["task"], payload["worktree_slug"], payload["feature"]]
            .map(&:to_s).map(&:strip).reject(&:empty?)
    return nil unless bound.include?(slug)

    root
  end
end

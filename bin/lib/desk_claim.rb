# frozen_string_literal: true

require "open3"
require_relative "desk_context"
require_relative "process_table"

# THE DESK IS THE BUILD CLAIM (devops-v3 design §7, "Claims and leases").
#
# A task is claimed while a desk bound to it exists on this machine: a worktree
# whose .agent-context.json names the task. There is no lease, no TTL and no
# renewer. It replaced a 120s lease (devops.claimed_session / claim_nonce /
# claim_expires_at) kept alive by a detached renewer and the status line. That
# lease failed in every direction measured: headless agents never renewed it,
# renewals outlived their builders, watcher shells orphaned, and its refusals sent
# builders to --steal on their own tasks.
#
# ONE CASE REFUSES, because it is the one case that can lose work: a DIFFERENT live
# session's desk is bound to the task AND that desk has uncommitted changes. Every
# other case claims freely, and the focus session arbitrates its own builders.
# `--steal` is the override for that one case; it takes the task, and the other
# desk's files stay on disk untouched.
module DeskClaim
  module_function

  # The desks that block `session` from claiming `slug`. Pure over its inputs so the
  # unit tier drives every case without a machine: `desks` is DeskContext.desks
  # output, and `dirty` answers true / false / nil for a worktree path.
  #
  # nil ("could not read its git status") BLOCKS. This gate only ever speaks for a
  # live foreign desk, and an unreadable one may be holding exactly the work the gate
  # exists to protect.
  def blocking(slug, desks:, session:, dirty:)
    DeskContext.holders_of(slug, desks: desks).select do |desk|
      DeskContext.live?(desk[:grade]) && !own?(desk, session) && dirty.call(path(desk)) != false
    end
  end

  # A desk is the mover's own when it names the mover's session, or the mover as its
  # parent (a focus session and the builders it spawned are one party).
  def own?(desk, session)
    wanted = session.to_s.strip
    return false if wanted.empty?

    detail = desk[:detail] || {}
    [detail[:session_id], detail[:parent_session_id]].map { |v| v.to_s.strip }.include?(wanted)
  end

  def path(desk)
    desk[:worktree] || File.dirname(desk[:path].to_s)
  end

  # true when the worktree has uncommitted changes, false when clean, nil when git
  # could not answer.
  def dirty?(dir)
    out, status = Open3.capture2("git", "-C", dir.to_s, "status", "--porcelain", err: File::NULL)
    return nil unless status.success?

    !out.strip.empty?
  rescue StandardError
    nil
  end

  # The on-disk read: every desk under `projects_dir`, graded against one process
  # table snapshot.
  def blocking_on_disk(slug, session:, projects_dir:)
    desks = DeskContext.desks(root: projects_dir, table: ProcessTable.process_table)
    blocking(slug, desks: desks, session: session, dirty: method(:dirty?))
  end

  # THE ARCHIVE HOLDER GUARD (devops-v3 4b-ii-b). `archived` is terminal and what
  # it can lose is uncommitted work in a desk. So it refuses exactly one case: a desk
  # bound to `slug` on this machine has uncommitted changes (or git could not say —
  # nil counts as dirty). Liveness and ownership do not matter here: an archive by
  # the desk's own session loses the same files. Pure over its inputs, like
  # #blocking.
  def dirty_bound(slug, desks:, dirty:)
    DeskContext.holders_of(slug, desks: desks).reject { |desk| dirty.call(path(desk)) == false }
  end

  def dirty_bound_on_disk(slug, projects_dir:)
    desks = DeskContext.desks(root: projects_dir, table: ProcessTable.process_table)
    dirty_bound(slug, desks: desks, dirty: method(:dirty?))
  end

  def archive_refusal(slug, blockers, force_command:)
    lines = ["⚠  refusing to archive #{slug}: a desk bound to it has uncommitted changes:"]
    blockers.each { |desk| lines << "     #{path(desk)}  (session #{short_session(desk)})" }
    lines << "   Archiving is terminal. Commit or discard that work, then re-run."
    lines << "   To archive anyway (the desk's files stay on disk): #{force_command}"
    lines
  end

  def refusal(slug, blockers, steal_command:, retry_command: nil)
    lines = ["⚠  #{slug} is bound to another live session's desk, and that desk has uncommitted changes:"]
    blockers.each { |desk| lines << "     #{path(desk)}  (session #{short_session(desk)})" }
    lines << "   Claiming it now could lose that work. Ask that session to commit, then re-run" \
             "#{retry_command ? ": #{retry_command}" : "."}"
    lines << "   To take the task anyway (that desk's files stay on disk): #{steal_command}"
    lines
  end

  def steal_notice(slug, blockers)
    ["--steal: claiming #{slug} over #{blockers.length} foreign desk(s) with uncommitted changes:",
     *blockers.map { |desk| "     #{path(desk)}  (session #{short_session(desk)})" }]
  end

  def short_session(desk)
    id = (desk[:detail] || {})[:session_id].to_s
    id.empty? ? "unrecorded" : "…#{id[-8..] || id}"
  end
end

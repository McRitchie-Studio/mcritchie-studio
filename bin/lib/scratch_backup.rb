# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "tmpdir"
require_relative "session_identity"

# ScratchBackup — save a pristine copy of a file and PROVE, at restore, that the
# copy you get back is the copy you saved.
#
# THE DEFECT THIS CLOSES, and why it is worse than the collision it sits beside.
#
# The agent harness hands every session a scratchpad keyed by SESSION, not by
# agent, so every sibling a session spawns writes to one directory. Agents park
# pristine copies there under generic names — measured 2026-09-01 on one live
# session: a shared, un-namespaced `backup/` holding `agent-worktree`,
# `atomic-event.good`, `manifest.good`, `test.good` and `BASELINE.sha`, with four
# different agents having touched the same test file that day.
#
# The sibling incident (docs/agents/modules/worktrees.md § "The session scratchpad
# is shared") was a COLLIDED LOG, and it left evidence: a `>` truncation against a
# writer holding an fd at offset 5407 produced a 2,586-byte NUL hole, so `file`
# reported `data` instead of `ASCII text`. Ugly, findable.
#
# A COLLIDED BACKUP LEAVES NOTHING. Two agents writing `manifest.good` write
# SEQUENTIALLY. There is no hole, no truncation, no corruption — the loser's
# restore point is simply gone, replaced by a perfectly well-formed file. You
# learn about it at RESTORE, which is the moment you least want a surprise: you
# are undoing a mutation and you get someone else's file instead of your own.
# Mutation testing is built on exactly this save/mutate/restore loop.
#
# THE TWO PROPERTIES, and they are deliberately belt-and-braces:
#
#   1. NAMESPACED BY ITS WRITER — makes the collision IMPOSSIBLE. Every entry
#      lives under `<root>/<owner>/backup/`, `owner` being the task slug (or the
#      session identity). There is no un-namespaced path to reach: `owner` is
#      appended to EVERY root candidate, and an unresolvable owner REFUSES rather
#      than defaulting to a shared directory. Within one owner, the entry name
#      carries a digest of the source's ABSOLUTE path, so one agent's two
#      `manifest.good`s in two repos do not collide either.
#
#   2. VERIFIED AT RESTORE — makes the collision DETECTABLE if property 1 is ever
#      defeated (a hand-passed `--owner`, a shared root, a future harness that
#      reuses ids). Save records a SHA-256 receipt beside the blob; restore
#      re-hashes the blob and REFUSES on mismatch, naming both digests. A silent
#      wrong-file restore becomes a loud refusal.
#
# Namespacing alone would be a convention, and a convention only protects the
# agents who read it. The receipt is what turns "please do not collide" into a
# fact the machine checks.
#
# WHAT IT IS NOT. It is not a backup SYSTEM — no history, no retention, no
# pruning, no directories. One file in, one file out, with a receipt. Anything
# larger belongs in git.
#
# ROOT RESOLUTION rots gracefully ON PURPOSE. Candidate 3 derives the harness
# scratchpad by GLOBBING for the session id, because the harness names that path
# only in an injected prompt block and no file in any repo carries it. If the
# harness layout changes, that candidate simply misses and the tmpdir fallback
# takes over — and because `owner` is appended to every candidate, the degraded
# path is still namespaced. Rot costs you a less convenient location, never the
# safety property.
#
# Unit tests: test/lib/scratch_backup_test.rb
# CLI (integration): test/lib/scratch_backup_cli_test.rb
module ScratchBackup
  # Raised for every refusal. The CLI turns it into a non-zero exit and a message;
  # nothing in this module rescues it, because every refusal here means a mutation
  # did NOT happen and the caller has to know that.
  class Refusal < StandardError; end

  RECEIPT_VERSION = 1

  # Sub-directory under the owner. Named for the thing agents already type, so the
  # tool's layout is recognisable to someone who has only ever done it by hand.
  BACKUP_DIR = "backup"

  # How much of the source path's digest goes in the entry name. 12 hex chars is
  # 48 bits — far past what a session's worth of file paths can collide on, and
  # short enough that `ls` in the directory is still readable.
  PATH_DIGEST_LENGTH = 12

  module_function

  # --- identity -------------------------------------------------------------

  # The namespace segment every entry sits under. Resolution, most explicit first:
  #
  #   1. `explicit`                   — the CLI's --owner
  #   2. SCRATCH_BACKUP_OWNER         — env seam (tests, wrappers)
  #   3. .agent-context.json          — the desk's task_slug, walking up from `dir`
  #   4. "<provider>-<session-id>"    — SessionIdentity, for a primary checkout
  #   5. REFUSE
  #
  # Step 5 is the whole design. A default owner would be a shared directory, and a
  # shared directory is the bug — so the tool would rather not run than write
  # somewhere two agents can both reach.
  def resolve_owner(explicit: nil, env: ENV, dir: Dir.pwd)
    from_explicit = sanitize_owner(explicit)
    return from_explicit if from_explicit

    from_env = sanitize_owner(env["SCRATCH_BACKUP_OWNER"])
    return from_env if from_env

    from_context = sanitize_owner(task_slug_from_context(dir))
    return from_context if from_context

    id, provider = SessionIdentity.identity(env)
    from_session = sanitize_owner(id.to_s.empty? ? nil : "#{provider || 'session'}-#{id}")
    return from_session if from_session

    raise Refusal, "cannot resolve an owner to namespace this backup under — pass --owner " \
                   "<task-slug>, or set SCRATCH_BACKUP_OWNER. Refusing rather than defaulting " \
                   "to a shared directory, which is the collision this tool exists to prevent"
  end

  # A filesystem-safe single path segment, or nil when the value names nothing.
  # Separators are COLLAPSED rather than rejected, and leading dots stripped, so
  # `--owner feat/foo` and `--owner ../evil` land inside the namespace they were
  # asked to create instead of climbing out of it.
  def sanitize_owner(value)
    slug = value.to_s.strip.downcase
                 .gsub(/[^a-z0-9._-]+/, "-")
                 .gsub(/-{2,}/, "-")
                 .gsub(/\A[-.]+|[-.]+\z/, "")
    return nil if slug.empty?

    slug
  end

  # The desk's task slug, from the .agent-context.json `bin/agent-worktree
  # bind-task` writes. Walks up from `dir` so it is found from any subdirectory of
  # the worktree. Best-effort: a malformed file is no context, not an error.
  def task_slug_from_context(dir = Dir.pwd)
    current = File.expand_path(dir.to_s)

    while current && File.directory?(current)
      candidate = File.join(current, ".agent-context.json")
      if File.file?(candidate)
        parsed = JSON.parse(File.read(candidate)) rescue nil
        slug = parsed.is_a?(Hash) ? parsed["task_slug"] : nil
        return slug unless slug.to_s.strip.empty?
      end

      parent = File.dirname(current)
      break if parent == current

      current = parent
    end

    nil
  rescue StandardError
    nil
  end

  # Who wrote this entry, for the receipt. Not a security claim and not used for
  # any decision — it is the line an operator reads when two receipts disagree and
  # the question is which agent to go ask.
  def writer_identity(env = ENV)
    id, provider = SessionIdentity.identity(env)
    return "unknown-#{Process.pid}" if id.to_s.empty?

    "#{provider}:#{id}:#{Process.pid}"
  end

  # --- location -------------------------------------------------------------

  # Where the per-owner namespaces live. `owner` is appended by `entry_dir`, never
  # here, so no candidate below is ever written to bare.
  def resolve_root(explicit: nil, env: ENV)
    from_explicit = explicit.to_s.strip
    return File.expand_path(from_explicit) unless from_explicit.empty?

    from_env = env["SCRATCH_BACKUP_ROOT"].to_s.strip
    return File.expand_path(from_env) unless from_env.empty?

    discovered_scratchpad(env) || File.join(Dir.tmpdir, "scratch-backup")
  end

  # The harness scratchpad for THIS session, or nil.
  #
  # Derived, not hardcoded: the only fact we hold is the session id, so we glob for
  # a `<something>/<something>/<session-id>/scratchpad` under the tmp bases. The
  # observed layout is `/tmp/claude-<uid>/<project-key>/<session-id>/scratchpad`,
  # and neither `claude-<uid>` nor the project key is spelled out here — a rename of
  # either still matches.
  def discovered_scratchpad(env = ENV)
    session = SessionIdentity.id(env)
    return nil if session.empty?

    tmp_bases(env).each do |base|
      patterns = [File.join(base, "*", "*", session, "scratchpad"),
                  File.join(base, "*", session, "scratchpad")]
      hit = Dir.glob(patterns).find { |path| File.directory?(path) }
      return hit if hit
    end

    nil
  rescue StandardError
    nil
  end

  def tmp_bases(env = ENV)
    [env["SCRATCH_BACKUP_TMPDIR"], "/tmp", Dir.tmpdir]
      .map { |base| base.to_s.strip }
      .reject(&:empty?)
      .uniq
  end

  def entry_dir(root:, owner:)
    File.join(root, owner, BACKUP_DIR)
  end

  # `<basename>-<digest of the absolute source path>`.
  #
  # The digest is what stops ONE owner colliding with itself: `manifest.good` in
  # turf-monster and `manifest.good` in mcritchie-studio are different entries. The
  # basename stays on the front only so the directory is legible to a human.
  def entry_name(source)
    absolute = File.expand_path(source.to_s)
    digest = Digest::SHA256.hexdigest(absolute)[0, PATH_DIGEST_LENGTH]

    "#{File.basename(absolute)}-#{digest}"
  end

  def blob_path(root:, owner:, source:)
    File.join(entry_dir(root: root, owner: owner), entry_name(source))
  end

  def receipt_path(root:, owner:, source:)
    "#{blob_path(root: root, owner: owner, source: source)}.receipt.json"
  end

  # --- save -----------------------------------------------------------------

  # Copy `source` into the owner's namespace and record a receipt for it.
  #
  # Refuses to overwrite a backup whose recorded content DIFFERS from what is on
  # disk now, unless `force`. That is the self-collision: you save a pristine copy,
  # mutate the file, absent-mindedly re-run save, and destroy the only copy of the
  # thing you were about to restore. Re-saving identical content is a no-op and is
  # always allowed, so an idempotent script never needs --force.
  def save(source:, root:, owner:, writer: writer_identity, force: false, now: Time.now)
    absolute = File.expand_path(source.to_s)
    raise Refusal, "no such file to back up: #{absolute}" unless File.file?(absolute)

    blob = blob_path(root: root, owner: owner, source: absolute)
    receipt_file = receipt_path(root: root, owner: owner, source: absolute)
    sha = file_digest(absolute)

    guard_overwrite!(receipt_file: receipt_file, sha: sha, absolute: absolute) unless force

    FileUtils.mkdir_p(File.dirname(blob), mode: 0o700)
    atomic_write(blob, File.binread(absolute))
    File.chmod(File.stat(absolute).mode & 0o7777, blob)

    receipt = {
      "version" => RECEIPT_VERSION,
      "source" => absolute,
      "sha256" => sha,
      "bytes" => File.size(absolute),
      "mode" => format("%04o", File.stat(absolute).mode & 0o7777),
      "owner" => owner,
      "writer" => writer,
      "saved_at" => now.utc.iso8601
    }
    atomic_write(receipt_file, "#{JSON.pretty_generate(receipt)}\n")

    receipt
  end

  def guard_overwrite!(receipt_file:, sha:, absolute:)
    existing = read_receipt(receipt_file)
    return if existing.nil?
    return if existing["sha256"] == sha

    raise Refusal, "#{absolute} already has a backup of DIFFERENT content " \
                   "(saved #{existing['sha256'][0, 12]} at #{existing['saved_at']} by " \
                   "#{existing['writer']}; on disk now #{sha[0, 12]}). Saving would destroy the " \
                   "restore point you are about to need. Re-run with --force if that is what you mean"
  end

  # --- verify ---------------------------------------------------------------

  # [status, detail] — never writes, never raises for a bad backup.
  #
  #   :ok       the blob on disk hashes to what the receipt recorded
  #   :missing  no receipt, or no blob beside it
  #   :mismatch the blob is NOT what was saved — the silent collision, caught
  #   :moved    the receipt records a different source path than the one asked for
  def verify(source:, root:, owner:)
    absolute = File.expand_path(source.to_s)
    blob = blob_path(root: root, owner: owner, source: absolute)
    receipt = read_receipt(receipt_path(root: root, owner: owner, source: absolute))

    return [:missing, "no backup recorded for #{absolute} under owner #{owner}"] if receipt.nil?
    return [:missing, "receipt exists but its blob is gone: #{blob}"] unless File.file?(blob)

    if receipt["source"] != absolute
      return [:moved, "receipt records #{receipt['source']}, not #{absolute}"]
    end

    actual = file_digest(blob)
    return [:ok, receipt] if actual == receipt["sha256"]

    [:mismatch, "backup content changed since it was saved: receipt #{receipt['sha256']}, " \
                "on disk #{actual}. Another writer overwrote this backup — restoring it would " \
                "hand you someone else's file"]
  end

  # --- restore --------------------------------------------------------------

  # Write the saved copy back over `source`, but ONLY after `verify` says the copy
  # is the one that was saved. Every non-:ok status refuses; nothing is written.
  #
  # `force` deliberately does NOT exist here. On save it is a judgement call about
  # your own file; here it would be a switch labelled "restore a file you have been
  # told is not yours", which is the entire failure this tool was written for.
  def restore(source:, root:, owner:)
    absolute = File.expand_path(source.to_s)
    status, detail = verify(source: absolute, root: root, owner: owner)
    raise Refusal, "refusing to restore #{absolute}: #{detail}" unless status == :ok

    blob = blob_path(root: root, owner: owner, source: absolute)
    FileUtils.mkdir_p(File.dirname(absolute))
    atomic_write(absolute, File.binread(blob))
    File.chmod(Integer(detail["mode"], 8), absolute) if detail["mode"]

    detail
  end

  # --- listing --------------------------------------------------------------

  # Every entry this owner holds, each with its verify status. Sorted by source so
  # two runs are diffable.
  def entries(root:, owner:)
    dir = entry_dir(root: root, owner: owner)
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, "*.receipt.json")).filter_map do |path|
      receipt = read_receipt(path)
      next if receipt.nil?

      status, detail = verify(source: receipt["source"], root: root, owner: owner)
      { "receipt" => receipt, "status" => status, "detail" => status == :ok ? nil : detail }
    end.sort_by { |entry| entry["receipt"]["source"].to_s }
  end

  # --- primitives -----------------------------------------------------------

  def file_digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def read_receipt(path)
    return nil unless File.file?(path)

    parsed = JSON.parse(File.read(path))
    parsed.is_a?(Hash) ? parsed : nil
  rescue StandardError
    nil
  end

  # Write to a sibling temp file and rename over the target.
  #
  # `File.rename` within one filesystem is atomic, so a reader sees the whole old
  # file or the whole new one — never a half-written blob whose digest matches
  # nothing. It also removes the one failure mode the sibling log incident was made
  # of: a truncating open against a file another process still holds an fd on.
  def atomic_write(path, content)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir, mode: 0o700)
    temp = File.join(dir, ".#{File.basename(path)}.tmp-#{Process.pid}-#{rand(1 << 32)}")

    begin
      File.binwrite(temp, content)
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp)
    end
  end
end

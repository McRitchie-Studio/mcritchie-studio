# frozen_string_literal: true

require "json"
require "open3"
require "time"

# R2Backup — the nightly undo for Cloudflare R2, which has no object versioning.
#
# One run mirrors <app>-production into <app>-backup/current/ with `rclone sync`,
# and `--backup-dir` first moves every object the sync would overwrite or delete
# into archive/<stamp>/. The run writes a receipt to _receipts/<stamp>.json. The
# procedure, the drill and the manual acts are the r2-backup SOP
# (docs/agents/agents/steffon/sops/r2-backup.md); this is its automation.
#
# THREE GUARDS, each closing a way a backup quietly becomes no backup:
#
#   1. A WIPE MUST NOT PROPAGATE. If production lost most of its objects since the
#      last good run, a sync would copy that loss into current/, leaving the lost
#      objects only in archive/, where the lifecycle rule expires them in 30 days.
#      So a sharp drop REFUSES the run (and the refusal alerts), and every sync is
#      capped with --max-delete as a second net.
#   2. EXIT 0 IS NOT SUCCESS. A run is good only when rclone exited 0 AND
#      current/ holds as many objects as production. The receipt records `ok`,
#      and a not-ok run exits non-zero so the workflow alerts.
#   3. COLLECTION NEEDS A FRESH GOOD RUN. gc deletes archive folders only when the
#      newest receipt is under 48 hours old and ok, so a broken backup can never
#      let collection eat the only history. It never touches current/.
#
# Unit tests: test/lib/r2_backup_test.rb
module R2Backup
  STAMP_FORMAT = "%Y-%m-%dT%H%M%SZ"
  STAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{6}Z\z/

  # A drop is a WIPE when production lost at least this share of the last good
  # run's objects AND at least MIN_DROP of them — a small bucket losing two files
  # is ordinary churn, not a wipe.
  DROP_SHARE = 0.2
  MIN_DROP = 10
  FRESH_HOURS = 48
  DEFAULT_DAYS = 30

  module_function

  def stamp(time = Time.now.utc) = time.utc.strftime(STAMP_FORMAT)

  def stamp?(value) = STAMP_PATTERN.match?(value.to_s)

  # Why a run must not proceed, or nil when it may. `last_count` is the production
  # count the last GOOD run saw (nil on a first run), `now_count` production's
  # count right now.
  def wipe_refusal(last_count, now_count)
    return nil if last_count.nil? || last_count.zero?

    dropped = last_count - now_count
    return nil if dropped <= 0
    return nil if dropped < MIN_DROP && now_count.positive?
    return nil if dropped < (last_count * DROP_SHARE) && now_count.positive?

    "production holds #{now_count} object(s), down #{dropped} from #{last_count} at the last good run — " \
      "refusing to mirror a possible wipe into current/"
  end

  # The --max-delete cap for a sync: a fifth of what current/ holds, never under
  # MIN_DROP, so ordinary deletes pass and a mass delete stops the sync.
  #
  # DOUBLED, because rclone counts more than one delete per object when
  # --backup-dir is set (the object is moved into the archive, then removed).
  # Measured on R2 2026-09-26 with rclone 1.75.1: deleting 12 objects tripped a
  # cap of 13 after only 3 left current/. A tripped cap stops the sync partway
  # (exit 7); that is safe, because every object it touched is already in the
  # archive and the next run finishes the job.
  def max_delete(current_count) = [MIN_DROP, (current_count.to_i * DROP_SHARE).ceil].max * 2

  # Whether a receipt records a good run. Receipts written before `ok` existed are
  # judged the way the SOP judged them: exit 0 and equal counts.
  def receipt_ok?(receipt)
    return receipt["ok"] == true if receipt.key?("ok")

    receipt["rclone_exit"].to_i.zero? &&
      receipt.dig("production", "count") == receipt.dig("current", "count")
  end

  # Why collection must not run, or nil. `newest` is [name, receipt-hash] for the
  # newest receipt, or nil when there is none.
  def gc_refusal(newest, now: Time.now.utc)
    return "no run receipt exists" if newest.nil?

    name, receipt = newest
    at = parse_stamp(name.delete_suffix(".json"))
    return "newest receipt #{name} has no readable stamp" if at.nil?
    return "newest receipt #{name} is older than #{FRESH_HOURS}h" if now - at > FRESH_HOURS * 3600
    return "newest run #{name} was not ok" unless receipt_ok?(receipt)

    nil
  end

  # The archive folders collection may delete: stamp-named, older than `days`.
  # Anything not stamp-named is left alone and reported by the caller.
  def expired_folders(folders, days:, now: Time.now.utc)
    cutoff = now - (days * 86_400)
    folders.map { |f| f.to_s.delete_suffix("/") }
           .select { |f| stamp?(f) && parse_stamp(f) < cutoff }
           .sort
  end

  # Built with Time.utc rather than Time.strptime: strptime reads the digits as
  # LOCAL time and the trailing Z as a literal, so on a Denver machine every stamp
  # lands six or seven hours late and the 48-hour freshness check drifts with it.
  def parse_stamp(value)
    return nil unless stamp?(value)

    y, mo, d, h, mi, s = value.match(/\A(\d{4})-(\d{2})-(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/).captures.map(&:to_i)
    Time.utc(y, mo, d, h, mi, s)
  rescue ArgumentError
    nil
  end

  # Runs the act against R2 through rclone. `shell` is injected so the unit
  # tests can drive it without a network: it takes an argv array and returns
  # [stdout, exit_status_integer].
  class Runner
    REMOTE = "r2"

    attr_reader :app, :log

    def initialize(app:, shell: nil, log: $stdout, clock: -> { Time.now.utc })
      @app = app
      @shell = shell || method(:system_shell)
      @log = log
      @clock = clock
    end

    def production = "#{REMOTE}:#{app}-production"
    def backup = "#{REMOTE}:#{app}-backup"

    # One run. Returns the receipt hash; the caller exits non-zero unless ok.
    # `accept_drop` is the operator saying a large delete in production was
    # deliberate: it lifts the wipe refusal and the --max-delete cap for this run
    # only, and the receipt records that it did.
    def run(accept_drop: false)
      stamp = R2Backup.stamp(@clock.call)
      last = newest_receipt(ok_only: true)
      now_count = count(production)
      if now_count.nil?
        return finish(stamp, ok: false, rclone_exit: -1, reason: "could not count #{production}")
      end

      refusal = accept_drop ? nil : R2Backup.wipe_refusal(last&.last&.dig("production", "count"), now_count)
      return finish(stamp, ok: false, rclone_exit: -1, reason: refusal, production: now_count) if refusal

      current_before = count("#{backup}/current") || 0
      cap = accept_drop ? [] : ["--max-delete", R2Backup.max_delete(current_before).to_s]
      _out, rc = rclone("sync", production, "#{backup}/current",
                        "--backup-dir", "#{backup}/archive/#{stamp}", *cap, "-q")
      prod_after = count(production)
      current_after = count("#{backup}/current")
      archived = count("#{backup}/archive/#{stamp}") || 0
      ok = rc.zero? && !prod_after.nil? && prod_after == current_after
      reason = if !rc.zero? then "rclone sync exited #{rc}"
               elsif !ok then "count mismatch: production #{prod_after.inspect}, current #{current_after.inspect}"
               end
      finish(stamp, ok: ok, rclone_exit: rc, reason: reason, accepted_drop: accept_drop,
                    production: prod_after, current: current_after, archived: archived)
    end

    # Collection. Returns [deleted_or_would_delete, refusal_or_nil].
    def gc(days: DEFAULT_DAYS, apply: false)
      refusal = R2Backup.gc_refusal(newest_receipt(ok_only: false), now: @clock.call)
      return [[], refusal] if refusal

      out, rc = rclone("lsf", "--dirs-only", "#{backup}/archive/")
      return [[], "could not list #{backup}/archive/ (rclone exit #{rc})"] unless rc.zero?

      folders = out.lines.map(&:strip).reject(&:empty?)
      folders.reject { |f| R2Backup.stamp?(f.delete_suffix("/")) }.each { |f| log.puts("  skip (not a stamp): #{f}") }
      expired = R2Backup.expired_folders(folders, days: days, now: @clock.call)
      expired.each do |f|
        if apply
          _o, prc = rclone("purge", "#{backup}/archive/#{f}")
          return [[], "purge of archive/#{f} failed (rclone exit #{prc})"] unless prc.zero?
        end
        log.puts("  #{apply ? 'deleted' : 'would delete'} archive/#{f}")
      end
      [expired, nil]
    end

    private

    def finish(stamp, ok:, rclone_exit:, reason: nil, accepted_drop: false, production: nil, current: nil, archived: 0)
      receipt = { "app" => app, "stamp" => stamp, "ok" => ok, "rclone_exit" => rclone_exit,
                  "production" => { "count" => production }, "current" => { "count" => current },
                  "archived" => { "count" => archived } }
      receipt["reason"] = reason if reason
      receipt["accepted_drop"] = true if accepted_drop
      json = JSON.generate(receipt)
      log.puts(json)
      _o, rc = rclone("rcat", "#{backup}/_receipts/#{stamp}.json", stdin: json)
      return receipt if rc.zero?

      # A run whose receipt write fails is NOT ok, however clean the copy: gc
      # reads only receipts, so a missing one would stall collection while the
      # job stayed green. This used to be a warning nobody read. From 2026-09-27
      # to -29 CI's apt rclone 1.60.1 exited 1 on every receipt (a 501
      # NotImplemented AFTER the upload; the objects landed intact), so the
      # warning cried wolf nightly and would have hidden a real loss. Failing
      # the run is what opens the alert issue.
      failure = "receipt write failed (rclone exit #{rc})"
      log.puts("ERROR: #{failure}")
      receipt.merge("ok" => false, "reason" => [receipt["reason"], failure].compact.join("; "))
    end

    # [name, hash] of the newest receipt (optionally the newest OK one), or nil.
    def newest_receipt(ok_only:)
      out, rc = rclone("lsf", "#{backup}/_receipts/")
      return nil unless rc.zero?

      out.lines.map(&:strip).select { |n| n.end_with?(".json") }.sort.reverse_each do |name|
        body, brc = rclone("cat", "#{backup}/_receipts/#{name}")
        next unless brc.zero?

        receipt = JSON.parse(body) rescue next
        return [name, receipt] if !ok_only || R2Backup.receipt_ok?(receipt)
      end
      nil
    end

    def count(path)
      out, rc = rclone("size", path, "--json")
      return nil unless rc.zero?

      JSON.parse(out)["count"]
    rescue JSON::ParserError
      nil
    end

    def rclone(*args, stdin: nil) = @shell.call(["rclone", *args], stdin)

    def system_shell(argv, stdin)
      out, status = Open3.capture2(*argv, stdin_data: stdin.to_s)
      [out, status.exitstatus || 1]
    end
  end
end

# frozen_string_literal: true

# [unit] R2Backup — the nightly R2 backup's decisions and its runner.
#
# The runner is driven against FakeR2, an in-memory stand-in for the handful of
# rclone verbs it uses (size, sync with --backup-dir and --max-delete, lsf, cat,
# rcat, purge), so each guard is proven by what it does to the buckets, not by
# which method it called: a wipe that is refused leaves current/ intact, a run
# whose counts disagree is not ok and says why, and collection never deletes
# anything but an expired stamp folder.

require "minitest/autorun"
require "stringio"
require "json"
require_relative "../../bin/lib/r2_backup"

class R2BackupTest < Minitest::Test
  NOW = Time.utc(2026, 9, 27, 9, 0, 0)

  # --- pure decisions ------------------------------------------------------------

  def test_wipe_refusal_allows_first_run_and_growth
    assert_nil R2Backup.wipe_refusal(nil, 0)
    assert_nil R2Backup.wipe_refusal(0, 0)
    assert_nil R2Backup.wipe_refusal(100, 140)
  end

  def test_wipe_refusal_allows_ordinary_churn
    assert_nil R2Backup.wipe_refusal(100, 85), "15% drop is below the share"
    assert_nil R2Backup.wipe_refusal(20, 12), "8 lost is below the minimum count"
  end

  def test_wipe_refusal_refuses_a_sharp_drop
    assert_match(/down 30 from 100/, R2Backup.wipe_refusal(100, 70))
  end

  def test_wipe_refusal_refuses_any_drop_to_zero
    refute_nil R2Backup.wipe_refusal(3, 0), "a small bucket emptied is still a wipe"
  end

  def test_max_delete_has_a_floor_and_scales
    assert_equal 10, R2Backup.max_delete(0)
    assert_equal 10, R2Backup.max_delete(30)
    assert_equal 200, R2Backup.max_delete(1000)
  end

  def test_receipt_ok_reads_the_flag_when_present
    assert R2Backup.receipt_ok?({ "ok" => true, "rclone_exit" => 1 })
    refute R2Backup.receipt_ok?({ "ok" => false, "rclone_exit" => 0 })
  end

  def test_receipt_ok_judges_a_legacy_receipt_by_exit_and_counts
    good = { "rclone_exit" => 0, "production" => { "count" => 2 }, "current" => { "count" => 2 } }
    mismatch = good.merge("current" => { "count" => 1 })
    assert R2Backup.receipt_ok?(good)
    refute R2Backup.receipt_ok?(mismatch), "exit 0 with unequal counts is a failed run"
  end

  def test_gc_refusal_cases
    fresh = R2Backup.stamp(NOW - 3600)
    stale = R2Backup.stamp(NOW - (49 * 3600))
    assert_equal "no run receipt exists", R2Backup.gc_refusal(nil, now: NOW)
    assert_match(/older than 48h/, R2Backup.gc_refusal(["#{stale}.json", { "ok" => true }], now: NOW))
    assert_match(/not ok/, R2Backup.gc_refusal(["#{fresh}.json", { "ok" => false }], now: NOW))
    assert_nil R2Backup.gc_refusal(["#{fresh}.json", { "ok" => true }], now: NOW)
  end

  def test_expired_folders_selects_only_old_stamps
    old = R2Backup.stamp(NOW - (31 * 86_400))
    young = R2Backup.stamp(NOW - (29 * 86_400))
    got = R2Backup.expired_folders(["#{old}/", "#{young}/", "current/", "notes/"], days: 30, now: NOW)
    assert_equal [old], got
  end

  # --- the runner, against an in-memory R2 ----------------------------------------

  # Buckets are hashes of key => body. Paths look like "r2:<bucket>/<prefix>".
  class FakeR2
    attr_reader :buckets, :calls

    def initialize(buckets) = (@buckets = buckets; @calls = [])

    def call(argv, stdin)
      @calls << argv
      _rclone, verb, *args = argv
      send("do_#{verb}", args, stdin)
    end

    def objects(path)
      bucket, prefix = split(path)
      (@buckets[bucket] || {}).select { |k, _| prefix.empty? || k.start_with?(prefix) }
                              .transform_keys { |k| k.delete_prefix(prefix) }
    end

    private

    def split(path)
      bucket, prefix = path.delete_prefix("r2:").split("/", 2)
      prefix = prefix.to_s
      prefix += "/" unless prefix.empty? || prefix.end_with?("/")
      [bucket, prefix]
    end

    def do_size(args, _) = [JSON.generate("count" => objects(args[0]).size), 0]

    def do_sync(args, _)
      src, dst = args[0], args[1]
      backup_dir = args[args.index("--backup-dir") + 1]
      cap = args[args.index("--max-delete") + 1].to_i
      source = objects(src)
      dest = objects(dst)
      deletes = dest.keys - source.keys
      return ["", 7] if deletes.size > cap # rclone's own exit when --max-delete trips

      dbucket, dprefix = split(dst)
      bbucket, bprefix = split(backup_dir)
      (deletes + source.keys.select { |k| dest.key?(k) && dest[k] != source[k] }).each do |k|
        @buckets[bbucket]["#{bprefix}#{k}"] = dest[k]
      end
      deletes.each { |k| @buckets[dbucket].delete("#{dprefix}#{k}") }
      source.each { |k, v| @buckets[dbucket]["#{dprefix}#{k}"] = v }
      ["", 0]
    end

    def do_lsf(args, _)
      path = args.last
      keys = objects(path).keys
      names = if args.include?("--dirs-only")
                keys.filter_map { |k| k.include?("/") ? "#{k.split('/').first}/" : nil }.uniq
              else
                keys.reject { |k| k.include?("/") }
              end
      [names.join("\n"), 0]
    end

    def do_cat(args, _)
      bucket, key = args[0].delete_prefix("r2:").split("/", 2)
      body = @buckets.dig(bucket, key)
      body ? [body, 0] : ["", 3]
    end

    def do_rcat(args, stdin)
      bucket, key = args[0].delete_prefix("r2:").split("/", 2)
      @buckets[bucket][key] = stdin
      ["", 0]
    end

    def do_purge(args, _)
      bucket, prefix = split(args[0])
      @buckets[bucket].delete_if { |k, _| k.start_with?(prefix) }
      ["", 0]
    end
  end

  def runner(fake, at: NOW) = R2Backup::Runner.new(app: "moms-app", shell: fake, log: StringIO.new, clock: -> { at })

  def fresh_fake(production)
    FakeR2.new("moms-app-production" => production, "moms-app-backup" => {})
  end

  def test_first_run_mirrors_and_writes_an_ok_receipt
    fake = fresh_fake("a.txt" => "1", "b.txt" => "1")
    receipt = runner(fake).run

    assert receipt["ok"], receipt["reason"]
    assert_equal({ "a.txt" => "1", "b.txt" => "1" }, fake.objects("r2:moms-app-backup/current"))
    stored = JSON.parse(fake.buckets["moms-app-backup"]["_receipts/#{R2Backup.stamp(NOW)}.json"])
    assert_equal true, stored["ok"]
  end

  def test_second_run_archives_overwritten_and_deleted_objects
    fake = fresh_fake("a.txt" => "v1", "b.txt" => "b")
    runner(fake, at: NOW).run
    fake.buckets["moms-app-production"] = { "a.txt" => "v2" }
    later = NOW + 86_400
    receipt = runner(fake, at: later).run

    assert receipt["ok"], receipt["reason"]
    archive = fake.objects("r2:moms-app-backup/archive/#{R2Backup.stamp(later)}")
    assert_equal({ "a.txt" => "v1", "b.txt" => "b" }, archive)
    assert_equal({ "a.txt" => "v2" }, fake.objects("r2:moms-app-backup/current"))
  end

  def test_a_wipe_is_refused_and_current_survives
    production = (1..50).to_h { |i| ["f#{i}", "x"] }
    fake = fresh_fake(production)
    runner(fake, at: NOW).run
    fake.buckets["moms-app-production"] = production.first(5).to_h
    receipt = runner(fake, at: NOW + 86_400).run

    refute receipt["ok"]
    assert_match(/possible wipe/, receipt["reason"])
    assert_equal 50, fake.objects("r2:moms-app-backup/current").size, "current/ must be untouched"
    refute(fake.calls.count { |c| c[1] == "sync" } > 1, "the refused run must not sync")
  end

  def test_max_delete_stops_a_mass_delete_the_count_guard_missed
    # 12 objects -> 0 after an ok run, but the last OK receipt is gone (expired),
    # so the count guard has nothing to compare: --max-delete is the second net.
    fake = fresh_fake((1..12).to_h { |i| ["f#{i}", "x"] })
    runner(fake, at: NOW).run
    fake.buckets["moms-app-backup"].delete_if { |k, _| k.start_with?("_receipts/") }
    fake.buckets["moms-app-production"] = {}
    receipt = runner(fake, at: NOW + 86_400).run

    refute receipt["ok"]
    assert_equal 7, receipt["rclone_exit"]
    assert_equal 12, fake.objects("r2:moms-app-backup/current").size
  end

  # rclone can exit 0 and still leave current/ short (an object written to
  # production mid-sync, a silently skipped key). That run is not ok.
  class LossyR2 < FakeR2
    def do_sync(args, stdin)
      out = super
      bucket, prefix = split(args[1])
      key = @buckets[bucket].keys.find { |k| k.start_with?(prefix) }
      @buckets[bucket].delete(key)
      out
    end
  end

  def test_exit_zero_with_a_count_mismatch_is_not_ok
    fake = LossyR2.new("moms-app-production" => { "a" => "1", "b" => "1" }, "moms-app-backup" => {})
    receipt = runner(fake).run

    refute receipt["ok"]
    assert_equal 0, receipt["rclone_exit"]
    assert_match(/count mismatch/, receipt["reason"])
  end

  def test_gc_refuses_after_a_failed_run_and_deletes_nothing
    fake = fresh_fake("a" => "1")
    fake.buckets["moms-app-backup"]["archive/#{R2Backup.stamp(NOW - (40 * 86_400))}/a"] = "old"
    fake.buckets["moms-app-backup"]["_receipts/#{R2Backup.stamp(NOW - 60)}.json"] = JSON.generate("ok" => false)
    deleted, refusal = runner(fake).gc(days: 30, apply: true)

    assert_empty deleted
    assert_match(/not ok/, refusal)
    assert_equal 1, fake.objects("r2:moms-app-backup/archive").size
  end

  def test_gc_apply_deletes_only_expired_stamp_folders
    fake = fresh_fake("a" => "1")
    runner(fake, at: NOW).run
    old = R2Backup.stamp(NOW - (40 * 86_400))
    young = R2Backup.stamp(NOW - (5 * 86_400))
    b = fake.buckets["moms-app-backup"]
    b["archive/#{old}/x"] = "1"
    b["archive/#{young}/y"] = "1"
    b["archive/not-a-stamp/z"] = "1"
    deleted, refusal = runner(fake).gc(days: 30, apply: true)

    assert_nil refusal
    assert_equal [old], deleted
    assert_equal({ "#{young}/y" => "1", "not-a-stamp/z" => "1" }, fake.objects("r2:moms-app-backup/archive"))
    assert_equal({ "a" => "1" }, fake.objects("r2:moms-app-backup/current"))
  end

  def test_gc_dry_run_deletes_nothing
    fake = fresh_fake("a" => "1")
    runner(fake, at: NOW).run
    old = R2Backup.stamp(NOW - (40 * 86_400))
    fake.buckets["moms-app-backup"]["archive/#{old}/x"] = "1"
    deleted, _ = runner(fake).gc(days: 30, apply: false)

    assert_equal [old], deleted
    assert fake.buckets["moms-app-backup"].key?("archive/#{old}/x")
  end
end

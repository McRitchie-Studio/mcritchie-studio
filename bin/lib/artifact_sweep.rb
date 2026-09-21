# frozen_string_literal: true

require "json"

# ArtifactSweep — what `bin/clean-artifacts` reclaims, and which managed Rails
# apps are still letting their local logs grow unbounded.
#
# Pure logic, no Rails, no processes of its own: discovery, planning, byte math,
# and the rotation verdict all take their inputs as arguments so the whole thing
# is unit-testable against a tmpdir. The CLI (bin/clean-artifacts) owns the
# terminal I/O; bin/release archive drives that CLI as a step.
#
# TWO DEFECTS THIS EXISTS TO FIX (both cost real disk before 2026-08-10):
#   1. The repo list was hardcoded to 2 of 9 repos, so chain-ops/log/localnet.log
#      reached 388 MB completely unswept.
#   2. Only <repo>/log was swept, never <repo>/.worktrees/*/log — where most of
#      the volume actually lives, because every desk carries its own.
module ArtifactSweep
  # A managed Rails repo is one with config/environments — that is what makes it
  # a Rails app, and it is discovered rather than listed so a NEW app is swept
  # the day it lands instead of the day someone remembers to add it here.
  RAILS_MARKER = File.join("config", "environments")

  # Rails' own default cap for a local log (config.load_defaults "7.1", when
  # Rails.env.local?). An app sitting exactly here has NOT adopted the engine's
  # cap — it is simply carrying the framework default, which is 100 MB PLUS a
  # rotated sibling, per environment.
  RAILS_DEFAULT_CAP = 100 * 1024 * 1024

  # The loosest cap we will call healthy. studio-engine caps development at
  # 16 MB; the headroom lets a host choose its own larger cap without being
  # nagged, while anything at Rails' 100 MB default still gets named.
  MAX_HEALTHY_CAP = 32 * 1024 * 1024

  # One regenerable thing to reclaim. `kind` is :truncate for a live log (keep
  # the inode — a running server holds it open) and :delete for everything else.
  Target = Struct.new(:path, :kind, :bytes, keyword_init: true)

  module_function

  # ---- discovery ----------------------------------------------------------

  # Every managed Rails repo directly under the projects root, sorted. Skips
  # dotfiles and anything that is not a directory.
  def rails_repos(root)
    Dir.children(root)
       .reject { |name| name.start_with?(".") }
       .map { |name| File.join(root, name) }
       .select { |path| File.directory?(File.join(path, RAILS_MARKER)) }
       .sort
  end

  # A repo's own checkout plus every isolated worktree under it. Worktrees are
  # where most of the log volume lives: every desk boots its own stack.
  def checkouts_for(repo)
    [repo] + Dir.glob(File.join(repo, ".worktrees", "*")).select { |p| File.directory?(p) }.sort
  end

  # ---- planning -----------------------------------------------------------

  # The regenerable artifacts in ONE checkout. Deliberately narrow: live logs
  # are truncated in place, rotated logs / cache output / coverage are deleted.
  # Never tmp/pids, tmp/sockets, tmp/storage, db/, storage/, .env, or anything
  # tracked by git.
  def targets_for(checkout)
    targets = []

    Dir.glob(File.join(checkout, "log", "*.log")).sort.each do |path|
      targets << Target.new(path: path, kind: :truncate, bytes: size_of(path))
    end

    # Rotated siblings: development.log.0, test.log.1, …
    Dir.glob(File.join(checkout, "log", "*.log.[0-9]*")).sort.each do |path|
      targets << Target.new(path: path, kind: :delete, bytes: size_of(path))
    end

    Dir.glob(File.join(checkout, "tmp", "cache", "*")).sort.each do |path|
      targets << Target.new(path: path, kind: :delete, bytes: size_of(path))
    end

    brakeman = File.join(checkout, "tmp", "brakeman.json")
    targets << Target.new(path: brakeman, kind: :delete, bytes: size_of(brakeman)) if File.file?(brakeman)

    coverage = File.join(checkout, "coverage")
    targets << Target.new(path: coverage, kind: :delete, bytes: size_of(coverage)) if File.directory?(coverage)

    targets
  end

  # The whole plan: every managed repo, every checkout under it, every target.
  def plan(root)
    repos = rails_repos(root)
    checkouts = repos.flat_map { |repo| checkouts_for(repo) }
    by_checkout = checkouts.to_h { |checkout| [checkout, targets_for(checkout)] }
                           .reject { |_checkout, targets| targets.empty? }

    {
      root: root,
      repos: repos,
      checkout_count: checkouts.size,
      worktree_count: checkouts.size - repos.size,
      by_checkout: by_checkout,
      bytes: by_checkout.values.flatten.sum(&:bytes)
    }
  end

  # ---- applying -----------------------------------------------------------

  # Reclaim the planned targets; returns the bytes actually freed. A target that
  # vanished between plan and apply is skipped, not fatal — this is a
  # best-effort sweep over paths that may be in use.
  def apply!(targets)
    targets.sum do |target|
      case target.kind
      when :truncate
        next 0 unless File.file?(target.path)

        File.open(target.path, File::WRONLY | File::TRUNC) { }
        target.bytes
      when :delete
        next 0 unless File.exist?(target.path)

        FileUtils.rm_rf(target.path, secure: true)
        target.bytes
      else
        0
      end
    rescue SystemCallError
      0
    end
  end

  # ---- rotation audit -----------------------------------------------------

  # Classify what a BOOTED app's logger actually reported. The input comes from
  # a real `bin/rails runner` in the app — never from reading its config files,
  # because a config that is set at the wrong point in the boot reads correct
  # and behaves broken. (That exact trap is why studio-engine's cap has to be
  # installed before Rails' own :initialize_logger.)
  #
  #   :ok       bounded at a sane cap
  #   :loose    rotating, but at/above Rails' own 100 MB default — i.e. NOT on
  #             the engine's cap. This is what a satellite that never inherited
  #             studio-engine looks like, and it is the whole reason the check
  #             cannot simply ask "is it rotating at all?": Rails rotates every
  #             local log by default, so that question answers "yes" forever.
  #   :none     not rotating at all (shift_age 0 or no log device)
  #   :unknown  the app could not be booted; reason carried alongside
  def rotation_verdict(cap:, shift_age:)
    return :none if shift_age.to_i <= 0 || cap.nil?
    return :loose if cap >= MAX_HEALTHY_CAP

    :ok
  end

  # The Ruby the audit runs INSIDE each app. Reads the live logger object the
  # app actually booted with, not its configuration.
  AUDIT_SNIPPET = <<~RUBY.freeze
    logger = Rails.logger.respond_to?(:broadcasts) ? Rails.logger.broadcasts.first : Rails.logger
    device = logger.instance_variable_get(:@logdev)
    STDOUT.puts("STUDIO_LOG_AUDIT " + {
      cap: device && device.instance_variable_get(:@shift_size),
      shift_age: device && device.instance_variable_get(:@shift_age),
      path: device && device.filename
    }.to_json)
  RUBY

  # Pull the audit payload back out of an app boot's stdout. Apps are chatty at
  # boot (deprecations, warnings), so the marker is matched anywhere in the
  # output rather than assuming a clean last line.
  def parse_audit_output(output)
    line = output.to_s.lines.reverse.find { |l| l.include?("STUDIO_LOG_AUDIT ") }
    return nil unless line

    JSON.parse(line.split("STUDIO_LOG_AUDIT ", 2).last.strip, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end

  # ---- coverage: is EVERY managed app PROVEN to cap its logs? --------------

  # WHY THIS EXISTS. A missing answer used to be shaped exactly like a clean one.
  # `rotation_missing: []` + `rotation_unknown: []` is what a machine where every
  # app is capped emits, AND what `--skip-audit` emits, AND what an unparseable
  # summary line degrades to in `bin/release archive` (sweep_summary returns {}
  # on purpose, so a sweep hiccup cannot abort a run whose board work already
  # landed). The archive's Exit Seam printed its rotation warnings only when
  # those lists were non-empty — so a run that audited NOTHING printed exactly
  # what a fully capped machine printed: silence.
  #
  # That is the hole `cap-loose-app-logs` was filed against: an app whose cap
  # cannot be PROVEN must be named, never passed over. So the verdict is
  # computed, not inferred from an empty list:
  #
  #   :capped      the audit ran and every app it reached reported a sane cap
  #   :uncapped    at least one app reported Rails' default, or no rotation
  #   :unproven    nothing read loose, but an app could not be booted — its cap
  #                is UNKNOWN, and unknown is not a pass
  #   :unaudited   the audit did not run (--skip-audit); nothing was checked
  #   :unreadable  the summary carried no audit fields at all
  #
  # Worst-first, so the headline reads :capped only when the audit ran AND every
  # app it reached was capped.
  ROTATION_COVERAGE_VERDICTS = %i[unreadable unaudited uncapped unproven capped].freeze

  # The engine version whose `studio.logger` initializer installs the cap. Below
  # this an app carries studio-engine and is still LOOSE, which is what three of
  # this machine's five loose apps look like — so the remedy line names the floor
  # rather than saying "adopt studio-engine" to a repo that already has it.
  ENGINE_CAP_FLOOR = "0.33.0"

  # Classify a `bin/clean-artifacts` summary hash (symbol keys, as
  # parse_summary returns). `nil` and a partial hash both answer :unreadable
  # rather than raising — a degraded summary is the case this guards.
  def rotation_coverage(summary)
    summary = summary.to_h
    return :unreadable unless summary.key?(:audited_envs)
    return :unaudited if Array(summary[:audited_envs]).empty?
    return :uncapped if Array(summary[:rotation_missing]).any?
    return :unproven if Array(summary[:rotation_unknown]).any?

    :capped
  end

  def rotation_proven?(summary)
    rotation_coverage(summary) == :capped
  end

  # The ONE wording for the audit's verdict, so `bin/clean-artifacts`' closing
  # report and `bin/release archive`'s Exit Seam can never disagree about what a
  # run proved. EVERY verdict returns at least one line — silence is the defect
  # this replaces, and an empty return would reintroduce it.
  def rotation_report_lines(summary)
    summary = summary.to_h
    missing = Array(summary[:rotation_missing])
    unknown = Array(summary[:rotation_unknown])

    case rotation_coverage(summary)
    when :unreadable
      ["⚠ LOG CAP NOT PROVEN: the sweep emitted no logger audit, so no app was checked. " \
       "Re-run bin/clean-artifacts and read its audit section — an empty result here is " \
       "silence, not a clean machine."]
    when :unaudited
      ["⚠ LOG CAP NOT PROVEN: the logger audit did not run (--skip-audit), so no app was " \
       "checked. An empty result here is silence, not a clean machine."]
    else
      lines = []
      if missing.any?
        lines << "⚠ MISSING LOG ROTATION: #{missing.join(', ')} — these apps have not adopted " \
                 "the studio-engine cap (needs >= #{ENGINE_CAP_FLOOR}); their local logs grow " \
                 "to Rails' #{human_bytes(RAILS_DEFAULT_CAP)} default"
      end
      if unknown.any?
        lines << "⚠ LOG CAP NOT PROVEN for: #{unknown.join(', ')} — the audit could not boot " \
                 "these, so the cap is UNKNOWN. Never read it as a pass"
      end
      lines << "✓ every audited app caps its local logs (#{Array(summary[:audited_envs]).join(', ')})" if lines.empty?
      lines
    end
  end

  # ---- reporting ----------------------------------------------------------

  def human_bytes(bytes)
    units = %w[B KB MB GB TB]
    value = bytes.to_f
    unit = 0
    while value >= 1024 && unit < units.size - 1
      value /= 1024
      unit += 1
    end
    format(unit.zero? ? "%d %s" : "%.1f %s", value, units[unit])
  end

  # The one machine-readable line bin/release archive parses out of the sweep.
  # Keeping it a single tagged JSON line means the human output above it can be
  # reformatted freely without breaking the conductor.
  SUMMARY_TAG = "clean-artifacts-summary:"

  def summary_line(payload)
    "#{SUMMARY_TAG} #{JSON.generate(payload)}"
  end

  def parse_summary(output)
    line = output.to_s.lines.reverse.find { |l| l.include?(SUMMARY_TAG) }
    return nil unless line

    JSON.parse(line.split(SUMMARY_TAG, 2).last.strip, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end

  def size_of(path)
    return 0 unless File.exist?(path)
    return File.size(path) if File.file?(path)

    Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
       .select { |p| File.file?(p) && !File.symlink?(p) }
       .sum { |p| File.size(p) rescue 0 }
  rescue SystemCallError
    0
  end
end

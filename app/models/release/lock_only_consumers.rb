class Release
  # The engine apps whose `accepted` carries ONLY the release tooling's own lock
  # bumps, and which therefore have no card to make a release carry them.
  #
  # THE GAP THIS CLOSES (task release-ships-lock-only-consumers, measured
  # 2026-11-09). The ship re-locks every engine app it did not carry to the
  # published final, on that app's `accepted` (bin/release.rb
  # #relock_cardless_consumers), and says the commit "waits on `accepted` for the
  # next release that carries the app". But the sweep promotes and deploys only
  # the repos a swept TASK names, so the next release never carried it either.
  # commercial-welding sat on 0.135.2 in production with 0.136.0, 0.137.0,
  # 0.141.0 and 0.141.1 bump commits on `accepted`; alex-build sat on 0.137.0.
  # Every engine fix since then missed their production.
  #
  # So `bin/release prepare` asks git which engine apps are in that state and
  # adds them to the promote, the QA deploy and the ship. A repo qualifies only
  # when EVERY commit `accepted` carries past `release` is a lock bump the
  # release tooling wrote: a single-parent commit whose subject is
  # `bump <gem> <version>[, …][ for QA]` and whose files are lock files only.
  # One other commit (a human's change with no card, a merge) and the repo does
  # not ride: that work needs a task, and the accepted-coverage guard and
  # `bin/release status` already name it.
  #
  # The repos ride the release as MEMBERLESS app groups. Prepare records them on
  # the release (metadata LOCK_ONLY_KEY) in the same transaction as the sweep,
  # and Release::Conductor.repo_plan adds a group for each, so prepare, ship,
  # finalize and rollback all read one plan.
  #
  # IO-free (bin/release `require_relative`s it): the CLI owns the git reads.
  module LockOnlyConsumers
    module_function

    # The release metadata key that holds the lock-only repos, in sweep order.
    LOCK_ONLY_KEY = "lock_only_repos".freeze

    # The repos DROPPED from this release, { repo => reason }. A lock-only repo
    # rides for nobody's card, so a failure of its own (a red gate, a QA that does
    # not boot, a production smoke that fails) drops it instead of stopping the
    # member apps (review of 2026-11-09: rantly's Eco dyno 503s in the last week
    # of each month). A dropped repo stays out of this release: #recorded and
    # #record both exclude it, so prepare, ship, finalize and rollback agree.
    DROPPED_KEY = "lock_only_dropped".freeze

    # The subject the release tooling writes on every lock bump: the prepare's
    # QA bump ("… for QA"), the ship's producer bump and the cardless re-lock.
    BUMP_SUBJECT = /\Abump [A-Za-z0-9_.-]+ [0-9][0-9A-Za-z.]*(, [A-Za-z0-9_.-]+ [0-9][0-9A-Za-z.]*)*( for QA)?\z/

    # The files a lock bump may change. The engine migrations ride the lock
    # commit (install_engine_migrations!), so db/schema.rb and an ENGINE-NAMED
    # migration count: `rails <gem>:install:migrations` names each copy
    # `<timestamp>_<name>.<gem_underscored>.rb`. An app's own migration has no such
    # suffix, so a hand commit that copies the tool's subject cannot carry one.
    ENGINE_MIGRATION = %r{\Adb/migrate/\d+_[a-z0-9_]+\.(studio_engine|solana_studio)\.rb\z}
    LOCK_FILE = %r{\A(Gemfile|Gemfile\.lock|db/schema\.rb)\z}
    LOCK_PATH = Regexp.union(LOCK_FILE, ENGINE_MIGRATION)

    # The `git log` format the CLI reads with (one record per commit):
    #   git log --format=<LOG_FORMAT> --name-only origin/release..origin/accepted
    RECORD_SEP = "\x1e".freeze
    FIELD_SEP  = "\x1f".freeze
    LOG_FORMAT = "%x1e%H%x1f%P%x1f%s".freeze

    # Parse LOG_FORMAT output into [{ "sha", "parents", "subject", "files" }].
    def parse_log(text)
      text.to_s.split(RECORD_SEP).filter_map do |record|
        next if record.strip.empty?

        header, *rest = record.split("\n")
        sha, parents, subject = header.to_s.split(FIELD_SEP, 3)
        next if sha.to_s.strip.empty?

        {
          "sha" => sha.strip,
          "parents" => parents.to_s.split,
          "subject" => subject.to_s.strip,
          "files" => rest.map(&:strip).reject(&:empty?)
        }
      end
    end

    # One commit the release tooling wrote to bump a lock?
    def lock_bump?(commit)
      commit = commit.to_h
      files = Array(commit["files"])
      Array(commit["parents"]).size == 1 &&
        BUMP_SUBJECT.match?(commit["subject"].to_s.strip) &&
        files.any? &&
        files.all? { |file| LOCK_PATH.match?(file.to_s) }
    end

    # True only when there IS a commit to carry and every one is a lock bump.
    def lock_only?(commits)
      list = Array(commits)
      list.any? && list.all? { |commit| lock_bump?(commit) }
    end

    # The repos to ask git about: the engine apps (Release::EngineConsumers.all)
    # that no swept member names, that ride this train, and that no other
    # train's active release holds. Order kept.
    def candidates(engine_apps:, member_repos:, train_repos: nil, held_repos: [])
      named = Array(member_repos).map(&:to_s)
      held  = Array(held_repos).map { |h| h.is_a?(Hash) ? (h["repo"] || h[:repo]).to_s : h.to_s }
      Array(engine_apps).map(&:to_s).reject do |repo|
        named.include?(repo) || held.include?(repo) ||
          (!train_repos.nil? && !Array(train_repos).map(&:to_s).include?(repo))
      end
    end

    # The repos the release carries: recorded and not dropped. Order kept.
    def recorded(metadata)
      gone = dropped(metadata).keys
      Array(metadata.to_h[LOCK_ONLY_KEY]).map(&:to_s).reject(&:empty?).uniq - gone
    end

    # { repo => reason } for every lock-only repo dropped from the release.
    def dropped(metadata)
      metadata.to_h[DROPPED_KEY].to_h.to_h { |repo, reason| [ repo.to_s, reason.to_s ] }
    end

    # The metadata after this run records `repos`: the union, earlier ones first.
    # A repo already dropped from this release is not recorded again.
    def record(metadata, repos)
      meta = metadata.to_h.dup
      gone = dropped(meta).keys
      meta[LOCK_ONLY_KEY] = (Array(meta[LOCK_ONLY_KEY]).map(&:to_s) + Array(repos).map(&:to_s))
                            .reject(&:empty?).uniq - gone
      meta
    end

    # The metadata after `drops` ({ repo => reason }) leave the release. The
    # first reason recorded for a repo stays.
    def drop(metadata, drops)
      meta = metadata.to_h.dup
      gone = dropped(meta)
      drops.to_h.each { |repo, reason| gone[repo.to_s] ||= reason.to_s }
      meta[DROPPED_KEY] = gone
      meta[LOCK_ONLY_KEY] = Array(meta[LOCK_ONLY_KEY]).map(&:to_s) - gone.keys
      meta
    end

    # The migrations a lock-only repo's commits carry, for the prepare line.
    def migrations(commits)
      Array(commits).flat_map { |c| Array(c["files"]) }.select { |f| ENGINE_MIGRATION.match?(f.to_s) }.uniq
    end

    # The repos to add to a repo plan: recorded, and not already in it.
    def extra_repos(metadata, planned)
      present = Array(planned).map(&:to_s)
      recorded(metadata).reject { |repo| present.include?(repo) }
    end

    # The `bin/release prepare` line for one repo that rides.
    def riding_line(repo, commits)
      bumps = Array(commits).map { |c| c["subject"].to_s.sub(/\Abump /, "").sub(/ for QA\z/, "") }
      found = migrations(commits).map { |f| File.basename(f) }
      carried = found.empty? ? "no migrations" : "#{found.size} engine migration(s): #{found.join(', ')}"
      "#{repo}: `accepted` carries only lock bumps (#{bumps.join('; ')}; #{carried}) — no card names it, so it " \
        "rides this release with no member: promoted, QA'd where it has a QA app, and deployed. A failure of its " \
        "own drops it, never the members"
    end

    # --- `bin/release status`: live engine lag -------------------------------

    # { "repo", "live", "reference" } for every app whose live lock trails the
    # reference version by a MINOR or more (0.137.0 against 0.141.1 counts;
    # 0.141.0 against 0.141.1 does not). `live_locks` is { repo => version or nil };
    # a nil or unparsable version is left to #unread_repos. Sorted by repo.
    def lagging(live_locks, reference)
      ref = version_or_nil(reference)
      return [] if ref.nil?

      live_locks.to_h.filter_map do |repo, version|
        live = version_or_nil(version)
        next if live.nil?
        next unless minor_behind?(live, ref)

        { "repo" => repo.to_s, "live" => live.to_s, "reference" => ref.to_s }
      end.sort_by { |row| row["repo"] }
    end

    # The repos whose live lock could not be read.
    def unread_repos(live_locks)
      live_locks.to_h.select { |_repo, version| version_or_nil(version).nil? }.keys.map(&:to_s).sort
    end

    # Is `live` at least one minor (or a major) behind `ref`?
    def minor_behind?(live, ref)
      live_seg = live.segments.first(2).map(&:to_i)
      ref_seg  = ref.segments.first(2).map(&:to_i)
      live_seg[1] ||= 0
      ref_seg[1]  ||= 0
      (live_seg <=> ref_seg) == -1
    end

    # The status lines for the lag read. `accepted_locks` is { repo => version }
    # read from each app's `accepted`, so a line can say whether the next
    # release will carry the app up.
    def status_lines(gem_name:, reference:, live_locks:, accepted_locks: {})
      return [ "#{gem_name}: cannot confirm the shipped version — no lag read" ] if version_or_nil(reference).nil?

      rows = lagging(live_locks, reference)
      lines = rows.map do |row|
        queued = accepted_locks.to_h[row["repo"]].to_s
        tail =
          if queued.empty?
            "`accepted` lock not read"
          elsif version_or_nil(queued) && !minor_behind?(version_or_nil(queued), version_or_nil(reference))
            "`accepted` locks #{queued}; the next `bin/release prepare` carries it when `accepted` holds lock bumps only"
          else
            "`accepted` locks #{queued} too; it needs a lock bump"
          end
        "LAGS #{row['repo']}: production locks #{gem_name} #{row['live']}, the last shipped is " \
          "#{row['reference']} — #{tail}"
      end
      unread = unread_repos(live_locks)
      lines << "cannot confirm #{unread.join(', ')}: the live (`main`) lock was not readable" if unread.any?
      lines << "every engine app's production is within one minor of #{gem_name} #{reference}" if lines.empty?
      lines
    end

    def version_or_nil(value)
      text = value.to_s.strip
      return nil if text.empty?

      Gem::Version.new(text)
    rescue ArgumentError
      nil
    end
  end
end

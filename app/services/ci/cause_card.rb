require Rails.root.join("bin/lib/ci_cause_detector").to_s

module Ci
  # One board card per CI CAUSE: a test, a setup fault or a harness fault that turned a
  # run red at a SHA a later run proved green. Alex McRitchie, 2026-11-06: a red that a
  # re-run turns green is a defect with a cause, never a retry. CiCauseCardJob reads
  # the red job's log and hands each cause here.
  #
  # FOLDED, NOT FANNED OUT. The card's slug comes from the cause's key (its spec file,
  # Minitest class or fault name), so every later occurrence of the same cause lands on
  # the same open card as one more row under metadata.ci_cause.occurrences, and the
  # board gains one card per cause, not one per red run. A cause whose card was shipped
  # or archived and then came back opens a fresh card (`-2`, `-3`), because the fix that
  # card shipped did not hold.
  #
  # ONE CARD ACROSS REPOS FOR AN OUTSIDE CAUSE. An infra cause (a GitHub 504 on a
  # toolchain download, an apt mirror, an image-pull quota) is not in any repo, so its
  # slug carries no repo (`ci-cause-infra-<key>`, CiCauseDetector.card_slug): one event
  # that reds six repos' jobs is one card with six-plus occurrences, each naming its
  # repo, and the card's repositories grow as they arrive. A card, not a ledger: the
  # ruling wants every red's cause on record where a builder can take it, and the
  # board already folds, counts and reopens a cause that comes back after a fix.
  #
  # The class (infra / harness / test / product) is CiCauseDetector's first read of the
  # log; the builder who takes the card confirms it. Task: deterministic-ci.
  class CauseCard
    MAX_OCCURRENCES = 25
    CLOSED_STAGES = %w[shipped archived].freeze
    RULING = "Alex McRitchie, 2026-11-06: \"Flaky is a terrible way to describe a system.\" " \
             "A test that goes red then green at the same SHA is a defect with a cause, never a retry."

    # occurrence: { "id" =>, "run_url" =>, "sha" =>, "job" =>, "green_run_url" => }
    def self.file!(repo:, cause:, occurrence:)
      new(repo, cause.transform_keys(&:to_sym), occurrence.transform_keys(&:to_s)).file!
    end

    def initialize(repo, cause, occurrence)
      @repo = repo.to_s
      @cause = cause
      @occurrence = occurrence.merge("evidence" => Array(cause[:evidence]).first(4), "seen_at" => Time.current.iso8601)
    end

    # ONE CAUSE FILES ONE AT A TIME. Two CiCauseCardJob runs for one red (the ingest
    # and the sweep, or a re-delivered webhook) used to race: the row lock on the open
    # card covers zero rows while no card exists, so both saw none, the first created
    # the card, and the second saw its slug taken and created `-2` (turf run
    # 42745469708: web-server-boot and -2, 123ms apart, one occurrence). So a filer
    # first takes a transaction-scoped advisory lock on the cause's base slug: the
    # second waits for the first to commit, then reads its card. And an occurrence a
    # card of this cause already holds, open or closed, files nothing (task
    # ci-cause-card-dedupe-census).
    #
    # Belt and braces: a create that still hits the unique slug (the index, or the
    # validation when the winner committed first) files again and folds into the
    # winner's card.
    def file!
      tries = 0
      begin
        Task.transaction(requires_new: true) do
          base = CiCauseDetector.card_slug(@repo, @cause)
          serialize!(base)
          held = card_holding_occurrence(base)
          next held if held

          open = open_card(base)
          open ? fold!(open) : create!(next_free_slug(base))
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:slug, :taken)

        tries += 1
        retry if tries < 3
        raise
      end
    end

    private

    # Held to the end of the outermost transaction; the key is the cause, not a row,
    # so it serializes the first create too.
    def serialize!(base)
      conn = Task.connection
      conn.execute("SELECT pg_advisory_xact_lock(hashtext(#{conn.quote("ci-cause-card:#{base}")}))")
    end

    # Every card this cause has had: the base slug and its `-2`, `-3` reopenings.
    def cards(base)
      Task.where(slug: base).or(Task.where("slug ~ ?", "^#{Regexp.escape(base)}-[0-9]+$"))
    end

    # A card of this cause, in any stage, that already lists this occurrence.
    def card_holding_occurrence(base)
      cards(base).where("metadata -> 'ci_cause' -> 'occurrences' @> ?::jsonb", [{ "id" => @occurrence["id"] }].to_json)
                 .order(:id).last
    end

    # The newest card for this cause that is still open, locked for the fold.
    def open_card(base)
      cards(base).where.not(stage: CLOSED_STAGES).order(:id).lock.last
    end

    def next_free_slug(base)
      return base unless Task.exists?(slug: base)

      (2..).lazy.map { |n| "#{base}-#{n}" }.find { |slug| !Task.exists?(slug: slug) }
    end

    def fold!(task)
      meta = task.metadata.deep_dup
      cause = meta["ci_cause"] ||= {}
      list = cause["occurrences"] = Array(cause["occurrences"])
      return task if list.any? { |o| o["id"] == @occurrence["id"] }

      list << @occurrence
      cause["occurrences"] = list.last(MAX_OCCURRENCES)
      cause["count"] = cause["count"].to_i + 1
      add_repo!(meta)
      task.update!(metadata: meta)
      task
    end

    def add_repo!(meta)
      cause = meta["ci_cause"]
      cause["repos"] = (Array(cause["repos"].presence || cause["repo"]) | [@repo])
      devops = meta["devops"] ||= {}
      devops["repositories"] = Array(devops["repositories"]) | [short_repo]
    end

    def short_repo = @repo.split("/").last

    def outside? = CiCauseDetector.outside?(@cause)

    def create!(slug)
      klass = @cause[:klass].to_s
      key = @cause[:key].to_s
      where = outside? ? "Outside every repo, first seen in #{@repo}" : @repo
      Task.create!(
        slug: slug,
        title: CiCauseDetector.title(klass, key),
        stage: "designed",
        priority: 1,
        description: "#{where}: #{@cause[:reason]}. Red at #{@occurrence['sha'].to_s[0, 8]} " \
                     "(#{@occurrence['run_url']}), green at the same SHA (#{@occurrence['green_run_url']}).",
        metadata: {
          "devops" => {
            "kind" => "bug",
            "repositories" => [short_repo],
            "risk_tags" => ["ci"],
            "acceptance" => ["#{File.basename(key)}'s cause is named and fixed at its source",
                             "the fix adds no retry and no fixed sleep",
                             "it passes 20 consecutive runs at one SHA"],
            "test_plan" => ["[unit] a regression test that fails on the cause, red before the fix"],
            "agent_context" => "#{RULING}\n\nCause class (first read from the log, confirm it): #{klass}. " \
                               "Key: #{key}.\nEvidence:\n#{Array(@cause[:evidence]).map { |l| "  #{l}" }.join("\n")}\n\n" \
                               "Every occurrence is under metadata.ci_cause.occurrences. Filed by CiCauseCardJob."
          },
          "ci_cause" => { "class" => klass, "key" => key, "repo" => @repo, "repos" => [@repo], "outside" => outside?,
                         "count" => 1, "occurrences" => [@occurrence] }
        }
      )
    end
  end
end

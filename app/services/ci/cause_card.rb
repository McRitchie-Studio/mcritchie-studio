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

    def file!
      Task.transaction do
        base = CiCauseDetector.slug(@repo, @cause[:key])
        open = open_card(base)
        open ? fold!(open) : create!(next_free_slug(base))
      end
    end

    private

    # The newest card for this cause that is still open, locked for the fold.
    def open_card(base)
      Task.where(slug: base).or(Task.where("slug ~ ?", "^#{Regexp.escape(base)}-[0-9]+$"))
          .where.not(stage: CLOSED_STAGES).order(:id).lock.last
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
      task.update!(metadata: meta)
      task
    end

    def create!(slug)
      klass = @cause[:klass].to_s
      key = @cause[:key].to_s
      Task.create!(
        slug: slug,
        title: CiCauseDetector.title(klass, key),
        stage: "designed",
        priority: 1,
        description: "#{@repo}: #{@cause[:reason]}. Red at #{@occurrence['sha'].to_s[0, 8]} " \
                     "(#{@occurrence['run_url']}), green at the same SHA (#{@occurrence['green_run_url']}).",
        metadata: {
          "devops" => {
            "kind" => "bug",
            "repositories" => [@repo.split("/").last],
            "risk_tags" => ["ci"],
            "acceptance" => ["#{File.basename(key)}'s cause is named and fixed at its source",
                             "the fix adds no retry and no fixed sleep",
                             "it passes 20 consecutive runs at one SHA"],
            "test_plan" => ["[unit] a regression test that fails on the cause, red before the fix"],
            "agent_context" => "#{RULING}\n\nCause class (first read from the log, confirm it): #{klass}. " \
                               "Key: #{key}.\nEvidence:\n#{Array(@cause[:evidence]).map { |l| "  #{l}" }.join("\n")}\n\n" \
                               "Every occurrence is under metadata.ci_cause.occurrences. Filed by CiCauseCardJob."
          },
          "ci_cause" => { "class" => klass, "key" => key, "repo" => @repo, "count" => 1, "occurrences" => [@occurrence] }
        }
      )
    end
  end
end

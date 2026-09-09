module Insights
  # Detects a STALE docs/agents/shared/insights.md — the failure that let the
  # tracked doc sit at "0 banked insights" for two months while the bank held five
  # (/tasks/insights-doc-never-regenerated).
  #
  # WHERE THIS CAN RUN, AND WHY THAT DECIDED THE DESIGN. The comparison needs BOTH
  # halves at once: the live bank AND the deployed copy of the tracked doc. Exactly
  # one place has both — a dyno on the board, where the doc ships inside the slug and
  # ActionGrade is the real bank. CI has the doc but its database is the empty TEST
  # database, and a desk worktree has the doc but an empty DEV database; in either
  # one the comparison passes vacuously or fails always. That is the same trap that
  # regenerating from a desk falls into, wearing a different hat. So the detector
  # runs as a scheduled job on the board (InsightsDocFreshnessJob) and its receipt is
  # an ErrorLog row; what CI owns instead is keeping the detector HONEST — see
  # test/services/insights/doc_freshness_test.rb.
  #
  # THE FRESHNESS BOUND IS CAUSAL, NOT CALENDAR. "Older than N days" cries wolf on a
  # doc that is still correct: when nobody banks a lesson, a six-month-old doc is
  # accurate and regenerating it changes only the date stamp. The bound used here is
  # "the bank was curated AFTER the doc was generated", which flags exactly the docs
  # that lost information and no others.
  module DocFreshness
    module_function

    # The generator's header line, and the only machine-readable claim the artefact
    # makes about itself. `DocGenerator.header` writes it; a round-trip test pins the
    # pair together, so rewording the header fails CI rather than blinding the
    # detector silently.
    HEADER = /^_Generated (\d{4}-\d{2}-\d{2}) from (\d+) banked insights?\./

    # Every stale verdict ends with the same instruction, because the obvious fix —
    # rerunning the generator wherever you happen to be standing — is the bug.
    REGENERATE = "Regenerate against the BOARD's database (a desk or CI database is " \
                 "empty and would write a false \"0 banked insights\"): see " \
                 "docs/agents/agents/alex/sops/share-insights.md.".freeze

    # A verdict. `stale?` is the question the job asks; `status` and `message` are
    # what the receipt carries.
    Result = Data.define(:status, :message, :recorded_count, :live_count, :generated_on, :path) do
      def stale? = status != :fresh
      def fresh? = status == :fresh
    end

    # Raised (and immediately rescued) by the job so the ErrorLog receipt carries a
    # real class, message and backtrace, the way every other incident here does.
    class StaleDocError < StandardError; end

    # Recover the count and generation date the artefact records about itself.
    # Returns nil when the header is no longer machine-readable — a blind detector is
    # itself a finding, never a pass.
    def parse(markdown)
      match = HEADER.match(markdown.to_s)
      return nil unless match

      { generated_on: Date.parse(match[1]), count: Integer(match[2], 10) }
    end

    # Compare the tracked doc against the live bank. Reads the DB twice (count and
    # latest curation) and the file once.
    def check(path: DocGenerator.default_path, live_count: nil, last_curated_at: nil)
      return missing(path) unless File.exist?(path)

      recorded = parse(File.read(path))
      live_count ||= DocGenerator.banked_insights.size
      return unparseable(path, live_count) if recorded.nil?

      last_curated_at = ActionGrade.banked.maximum(:updated_at) if last_curated_at.nil?

      verdict(path, recorded, live_count, last_curated_at)
    end

    # ── verdicts ──────────────────────────────────────────────────────────────

    def verdict(path, recorded, live_count, last_curated_at)
      if recorded[:count] != live_count
        return drifted(path, recorded, live_count)
      end

      if curated_after?(last_curated_at, recorded[:generated_on])
        return recurated(path, recorded, live_count, last_curated_at)
      end

      Result.new(status: :fresh, recorded_count: recorded[:count], live_count: live_count,
                 generated_on: recorded[:generated_on], path: path.to_s,
                 message: "insights.md is current: #{live_count} banked, generated " \
                          "#{recorded[:generated_on]}.")
    end

    # The doc records a DATE, not a timestamp, so same-day curation after a
    # generation is inside the artefact's own resolution and is not flagged here. It
    # is not missed in practice: banking a lesson changes the COUNT, which the
    # stricter check above catches on the same run.
    #
    # `end_of_day` resolves in `Time.zone`, which is deliberate and load-bearing:
    # the header's date was itself written by `strftime` on a `Time.current`, so
    # both sides of this comparison read the day in the same zone. Building the
    # other side with a zone-naive `Date#to_time` instead shifts the boundary by the
    # machine's UTC offset and flags a same-day edit as drift.
    def curated_after?(last_curated_at, generated_on)
      return false if last_curated_at.nil?

      last_curated_at > generated_on.end_of_day
    end

    def drifted(path, recorded, live_count)
      Result.new(
        status: :count_drift, recorded_count: recorded[:count], live_count: live_count,
        generated_on: recorded[:generated_on], path: path.to_s,
        message: "insights.md is STALE: it records #{recorded[:count]} banked " \
                 "#{recorded[:count] == 1 ? 'insight' : 'insights'} (generated " \
                 "#{recorded[:generated_on]}) but the bank holds #{live_count}. " \
                 "#{REGENERATE}"
      )
    end

    def recurated(path, recorded, live_count, last_curated_at)
      Result.new(
        status: :content_drift, recorded_count: recorded[:count], live_count: live_count,
        generated_on: recorded[:generated_on], path: path.to_s,
        message: "insights.md is STALE: the count still matches at #{live_count}, but the " \
                 "bank was curated #{last_curated_at.to_date} — after the doc was generated " \
                 "#{recorded[:generated_on]}, so an edited lesson never reached it. #{REGENERATE}"
      )
    end

    def unparseable(path, live_count)
      Result.new(
        status: :unparseable, recorded_count: nil, live_count: live_count,
        generated_on: nil, path: path.to_s,
        message: "insights.md no longer carries a machine-readable " \
                 "\"_Generated <date> from <n> banked insights\" header, so staleness can no " \
                 "longer be detected there. Restore the generated header. #{REGENERATE}"
      )
    end

    def missing(path)
      Result.new(
        status: :missing, recorded_count: nil, live_count: nil, generated_on: nil,
        path: path.to_s,
        message: "insights.md is missing at #{path}. #{REGENERATE}"
      )
    end
  end
end

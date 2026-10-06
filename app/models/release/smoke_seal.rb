require "time"

class Release
  # The persisted production smoke SEAL — the post-ship verdict of the read-only
  # @qa-readonly suite (bin/prod-smoke) run against PRODUCTION after the ship's
  # `/up` hard-gate. A SEAL, not a gate: it records a verdict (green/red) on the
  # Release AFTER the deploy already happened. A red seal ALERTS + recommends a
  # rollback but NEVER aborts or auto-rolls-back the ship — the operator stays the
  # gate (see bin/release step 5c).
  #
  # Pure value object: no ActiveRecord, no IO — so the verdict-building +
  # rollback-guidance logic is unit-testable in isolation. Persisted as the
  # releases.smoke_seal jsonb ({status, summary, checked_at}); Release#smoke_seal
  # rehydrates it via .from_h, and Release#record_smoke_seal! stores .to_h.
  #
  # Rails-FREE (plain Ruby, like Release::Cli / Release::ShipSequence) so
  # bin/release can `require_relative` it standalone — the rollback guidance it
  # prints on a red seal then comes from the SAME source the notes/board read.
  class SmokeSeal
    GREEN = "green"
    RED   = "red"
    STATUSES = [GREEN, RED].freeze

    attr_reader :status, :summary, :checked_at

    # Build a seal from a smoke RESULT — passed? → green, else red. `checked_at`
    # defaults to now (UTC) so a recorded seal always carries a timestamp.
    def self.from_result(passed:, summary: nil, checked_at: Time.now.utc)
      new(status: passed ? GREEN : RED, summary: summary, checked_at: checked_at)
    end

    # Rehydrate from the stored jsonb hash, or nil when unsealed (blank hash, or a
    # row predating the column). Tolerates string OR symbol keys and a missing/odd
    # status (→ nil, so the board/notes simply omit the badge).
    def self.from_h(hash)
      return nil unless hash.is_a?(Hash)

      status = (hash["status"] || hash[:status]).to_s
      return nil unless STATUSES.include?(status)

      new(
        status: status,
        summary: hash["summary"] || hash[:summary],
        checked_at: parse_time(hash["checked_at"] || hash[:checked_at])
      )
    end

    # Best-effort time parse — a stored ISO8601 string, an already-parsed Time, or
    # nil. Never raises (a malformed timestamp must not break a board render).
    def self.parse_time(value)
      return value if value.is_a?(Time)
      return nil if value.nil? || value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def initialize(status:, summary: nil, checked_at: nil)
      @status     = status.to_s
      @summary    = summary.to_s.strip
      @checked_at = checked_at
    end

    def green? = status == GREEN
    def red?   = status == RED

    # 🟢 / 🔴 — the board badge + the lead glyph on the verdict line.
    def badge = green? ? "🟢" : "🔴"
    def label = green? ? "passed" : "FAILED"

    def to_h
      { "status" => status, "summary" => summary, "checked_at" => checked_at&.utc&.iso8601 }
    end

    # One-line verdict for release notes / Discord / the board tooltip / the CLI:
    #   "🟢 Production smoke seal: passed — <summary>"
    #   "🔴 Production smoke seal: FAILED — <summary>"
    def verdict_line
      base = "#{badge} Production smoke seal: #{label}"
      summary.empty? ? base : "#{base} — #{summary}"
    end

    # The rollback to surface on a RED seal (an empty array on green). NON-BLOCKING:
    # the seal never rolls back on its own; these are what to RUN if the operator
    # decides to. `bin/release rollback` plans first and deploys only with --mode,
    # redeploying every app the release shipped at its previous SHA (main stays put).
    def rollback_commands(repo: "mcritchie-studio", deployed_sha: nil, release_slug: nil)
      return [] if green?

      sha = deployed_sha.to_s.strip
      sha = "<release-merge-sha>" if sha.empty?
      rel = release_slug.to_s.strip
      rel = "<release-slug>" if rel.empty?
      [
        "bin/release rollback #{rel}   # the plan: each app's previous shipped SHA and the schema check; deploys nothing",
        "bin/release rollback #{rel} --mode ask   # redeploy each app at its previous SHA; main is untouched",
        "then revert #{sha} in #{repo} on accepted through a task, or the next ship redeploys it"
      ]
    end

    def ==(other)
      other.is_a?(SmokeSeal) && other.to_h == to_h
    end
  end
end

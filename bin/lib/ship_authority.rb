# frozen_string_literal: true

# bin/lib/ship_authority.rb — HOW `bin/release ship` takes production authority.
#
# THE PRODUCTION WINDOW (docs/agents/system/devops-v3-design.md section 6,
# decision 2). Three modes, one seam in bin/release.rb:
#
#   ask    the interactive confirm prompt — holds until a human answers (today's
#          behaviour, kept verbatim).
#   timed  posts the ship_authorization REQUEST on the release (a
#          `ship_authorized started` event carrying the window end), then waits
#          up to `operator_windows.production_minutes` for an operator GRANT —
#          the Approve button on /deployments, or a scripted grant through the
#          events API. On lapse it proceeds ONLY when G3 Candidate is green on the
#          release and no member carries an open escalation; otherwise it refuses
#          and names why. The default, from config/release_builder.yml.
#   auto   proceeds on green with no prompt — `--yes` semantics.
#
# Every mode records the SAME two events (`ship_authorized` started → completed),
# so the /deployments tracker's Confirming/Confirmed stamps and the Approve
# button see one shape whatever the launch chose. The grant and ship's own
# completion share the conductor's idempotency key, so a grant that lands during
# the wait and the completion ship records afterwards are ONE row.
#
# A timed run's three rows each key on the WINDOW they belong to
# (idempotency_key below): a re-run posts a fresh request, and its grant can
# never be answered by the previous run's row. A LAPSE is keyed apart from a
# grant and flagged `lapsed`, so Release#ship_authorization_granted? never reads
# a lapse — least of all an earlier run's — as the operator's grant.
#
# Rails-free, with every side effect injected (recorder / reader / confirmer /
# say / clock / sleeper), so each firing condition is unit-tested without a
# release, a prod board, or a wall clock (test/lib/ship_authority_test.rb).
# FAIL-CLOSED at the lapse: a release the reader could not read at the window
# end is a refusal, never a proceed.
require "time"
require_relative "../../app/models/devops/windows"

module ShipAuthority
  class Refused < StandardError; end

  STEP = "ship_authorized"
  PROMPT = "Deploy this release to production?"
  # One prod-board read per poll (a `heroku run` on PROD), so the cadence is
  # coarse; the last sleep is trimmed to the window end so lapse is read on time.
  POLL_INTERVAL_S = 45

  module_function

  # The conductor's idempotency key for a timed run's event, scoped to the window
  # it belongs to; nil (the caller's default key) for an ask/auto event, which
  # carries no window. Release#grant_ship_authorization! derives the SAME grant
  # key from the latest request, so the web Approve and ship's own completion
  # stay one row per run.
  def idempotency_key(release_slug, status, metadata)
    ends_at = metadata.to_h["window_ends_at"].to_s
    return nil if ends_at.empty?

    lapse = status.to_s == "completed" && metadata.to_h["lapsed"] ? "lapsed:" : ""
    "#{release_slug}:#{STEP}:#{status}:#{lapse}#{ends_at}"
  end

  # explicit `--mode` wins; else `--yes` alone means auto; else the config default.
  # `config_mode` may be a callable so the YAML is read only when it decides.
  def resolve_mode(explicit:, assume_yes:, config_mode:)
    return Devops::Windows.validate_mode!(explicit) unless explicit.nil? || explicit.to_s.strip.empty?
    return "auto" if assume_yes

    value = config_mode.respond_to?(:call) ? config_mode.call : config_mode
    Devops::Windows.validate_mode!(value, source: "production_ship.mode")
  end

  # Take authority in `mode`. Returns :confirmed / :auto / :granted /
  # :lapsed_proceed / :dry, or raises Refused with the operator-facing reason.
  #   recorder.call(status, metadata)     records `ship_authorized <status>`
  #   reader.call(blockers: bool)         → {"granted"=>, "granted_by"=>, "granted_via"=>, "blockers"=>[]} or nil
  #   confirmer.call(prompt)              → bool (the ask prompt; honours --yes upstream)
  #   say.call(line)                      progress lines
  def take!(mode:, release_slug:, minutes:, recorder:, reader:, confirmer:, say:,
            clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) }, dry: false, interval: POLL_INTERVAL_S)
    case mode.to_s
    when "ask"
      recorder.call("started", { "mode" => "ask" })
      raise Refused, "aborted — production deploy not confirmed" unless confirmer.call(PROMPT)

      recorder.call("completed", { "mode" => "ask", "granted_via" => "confirm" })
      :confirmed
    when "auto"
      recorder.call("started", { "mode" => "auto" })
      recorder.call("completed", { "mode" => "auto", "granted_via" => "auto" })
      :auto
    when "timed"
      timed!(release_slug: release_slug, minutes: minutes, recorder: recorder, reader: reader, say: say,
             clock: clock, sleeper: sleeper, dry: dry, interval: interval)
    else
      raise Refused, "unknown ship mode #{mode.inspect} (ask|timed|auto)"
    end
  end

  def timed!(release_slug:, minutes:, recorder:, reader:, say:, clock:, sleeper:, dry:, interval:)
    opened = clock.call
    ends_at = opened + (minutes * 60)
    recorder.call("started", { "mode" => "timed", "window_minutes" => minutes, "window_ends_at" => ends_at.utc.iso8601 })
    say.call("  production window: #{minutes} min, until #{ends_at.utc.iso8601} — grant with Approve on /deployments (#{release_slug}); " \
             "on lapse the ship proceeds only with G3 green and no open escalation")
    if dry
      say.call("  [dry-run] would wait up to #{minutes} min for the grant, then read G3 + escalations at the window end")
      return :dry
    end

    loop do
      now = clock.call
      lapsed = now >= ends_at
      state = reader.call(blockers: lapsed)

      if state.is_a?(Hash) && state["granted"]
        via = state["granted_via"].to_s.empty? ? "grant" : state["granted_via"]
        say.call("  ✓ production authority granted by #{state['granted_by'].to_s.empty? ? 'the operator' : state['granted_by']} (#{via})")
        recorder.call("completed", { "mode" => "timed", "granted_via" => via, "window_ends_at" => ends_at.utc.iso8601 })
        return :granted
      end

      if lapsed
        # The one read that decides. Unreadable is a refusal, never a proceed.
        raise Refused, "production window lapsed at #{ends_at.utc.iso8601} and the release could not be read at the window end — " \
                       "nothing deployed. Re-run to open a fresh window, then grant with Approve on /deployments while it waits." unless state.is_a?(Hash)

        blockers = Array(state["blockers"])
        if blockers.empty?
          say.call("  production window lapsed at #{ends_at.utc.iso8601} with no answer — G3 green, no open escalation: proceeding on the timed default")
          recorder.call("completed", { "mode" => "timed", "lapsed" => true, "granted_via" => "window-lapse",
                                       "window_ends_at" => ends_at.utc.iso8601 })
          return :lapsed_proceed
        end
        raise Refused, "production window lapsed at #{ends_at.utc.iso8601} but the ship may not proceed on its own: " \
                       "#{blockers.join('; ')}. Nothing deployed. Re-run, then grant with Approve on /deployments while the new window is open " \
                       "(a grant made before the re-run answers the old request, not the new one), or re-run with --mode ask."
      end

      left = (ends_at - now).ceil
      say.call("  waiting for production authority — #{Devops::Windows.format_clock(left)} left" \
               "#{state.nil? ? ' (last read failed; retrying)' : ''}")
      sleeper.call([interval, left].min)
    end
  end
end

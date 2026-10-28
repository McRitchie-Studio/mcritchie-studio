# frozen_string_literal: true

class Release
  # THE DEVNET GAUNTLET: a green contest-rehearsal on QA before a Turf release ships.
  #
  # When a release carries turf-monster or turf-vault work, qa-release's exit seam
  # includes Turf Monster's `contest-rehearsal` on QA (devnet: create, enter, play,
  # settle with a real on-chain payout, close), recorded on the release as a
  # completed `devnet_gauntlet` ReleaseEvent. `bin/release prepare` runs it and
  # records it once QA is green (Release::DevnetGauntletRun). Alex McRitchie, 2026-10-11: "it just feels right
  # to run a devnet gauntlet on the package before giving production the green light."
  # `bin/release ship` reads the record in its decision snapshot and refuses a Turf
  # release without it (docs/agents/agents/steffon/sops/production-deploy.md).
  #
  # IO-free, like Release::ShipSequence: bin/release requires this file directly.
  module DevnetGauntlet
    STEP = "devnet_gauntlet"
    # The repos whose work moves contest money, on devnet as on mainnet.
    REPOS = %w[turf-monster turf-vault].freeze
    # The override, for Alex McRitchie's words only (a broken devnet, a release whose Turf
    # change cannot touch a contest). It records nothing; the ship prints it.
    SKIP_FLAG = "--skip-devnet-gauntlet"

    # The fragment of the ship's production snapshot read (inside its `{…}.to_json`):
    # the NEWEST terminal gauntlet event (completed or failed), or nil. A completed
    # record followed by a failed one is a red gauntlet, so the newest decides.
    # Plain `where`, so it reads on a production board that predates this file.
    SNAPSHOT_RUBY = "devnet_gauntlet: r.release_events.where(step: '#{STEP}', status: %w[completed failed])" \
                    ".order(:occurred_at, :id).last&.slice('occurred_at', 'actor', 'metadata', 'status')".freeze

    module_function

    def required?(repo_names) = (Array(repo_names).map(&:to_s) & REPOS).any?

    def turf_repos(repo_names) = Array(repo_names).map(&:to_s) & REPOS

    # THE BINDING. A green gauntlet proves the Turf code it ran against and nothing
    # newer: its metadata["shas"] names the QA-deployed SHA of each Turf repo, and it
    # covers a release only while every Turf repo's SHA there equals `shas` (the SHAs
    # QA runs now, or the SHAs the ship is about to ship). A record with no SHAs, a
    # failed one, or one for other code covers nothing.
    def covers?(record, turf:, shas:)
      return false unless record.is_a?(Hash) && record.fetch("status", "completed") == "completed"

      tested = record.dig("metadata", "shas")
      return false unless tested.is_a?(Hash)

      Array(turf).all? do |repo|
        want = shas.to_h[repo].to_s
        !want.empty? && tested[repo].to_s == want
      end
    end

    # [verdict, message]. verdict is one of
    #   :not_required  the release carries no Turf repo
    #   :recorded      the newest gauntlet is green and tested the SHAs being shipped
    #   :waived        not recorded, and the operator passed SKIP_FLAG with words
    #   :unknown       the snapshot carried no answer (an older reader): warn, proceed
    #   :refused       none, a red one newest, or a green one for other Turf SHAs
    # `shas` is { repo => sha } the ship ships.
    def verdict(repos:, snapshot:, shas: {}, waiver: nil)
      turf = turf_repos(repos)
      return [:not_required, nil] if turf.empty?

      unless snapshot.is_a?(Hash) && snapshot.key?(STEP)
        return [:unknown, "the release snapshot did not say whether a devnet gauntlet ran for #{turf.join(', ')}; " \
                          "confirm a green contest-rehearsal on QA before this ship goes further"]
      end

      recorded = snapshot[STEP]
      if covers?(recorded, turf: turf, shas: shas)
        by = recorded["actor"].to_s.strip
        return [:recorded, "devnet gauntlet recorded #{recorded["occurred_at"]}#{" by #{by}" unless by.empty?} " \
                           "for #{turf.map { |r| "#{r}@#{shas.to_h[r].to_s[0, 7]}" }.join(', ')}"]
      end

      reason = refusal(turf, recorded, shas)
      words = waiver.to_s.strip
      unless words.empty?
        what = recorded.is_a?(Hash) ? "NO green devnet gauntlet covers the #{turf.join(', ')} SHAs this ship ships" : "NO devnet gauntlet is recorded for #{turf.join(', ')}"
        return [:waived, "#{what}; shipping on #{SKIP_FLAG}: \"#{words}\""]
      end

      [:refused, reason]
    end

    def refusal(turf, recorded = nil, shas = {})
      "this release carries #{turf.join(' and ')} and #{missing_phrase(recorded, turf, shas)}. Re-run `bin/release prepare`, " \
        "which runs Turf Monster's contest-rehearsal on QA (docs/agents/agents/turf_monster/sops/contest-rehearsal.md) " \
        "to a green close and records it (or, for a hand-run rehearsal, POST " \
        "/api/v1/releases/current/events/#{STEP}/complete with metadata.shas naming each Turf repo's QA SHA), " \
        "then re-run the ship. " \
        "Only on Alex McRitchie's words: #{SKIP_FLAG} \"<his words>\"."
    end

    def missing_phrase(recorded, turf, shas)
      return "has NO devnet gauntlet recorded" unless recorded.is_a?(Hash)
      return "its newest devnet gauntlet is RED (failed #{recorded['occurred_at']})" if recorded["status"] == "failed"

      tested = recorded.dig("metadata", "shas")
      tested = {} unless tested.is_a?(Hash)
      "has NO devnet gauntlet recorded for the Turf code it ships: the newest green one tested " \
        "#{turf.map { |r| "#{r}@#{tested[r].to_s.empty? ? '?' : tested[r].to_s[0, 7]}" }.join(', ')}, " \
        "this ship ships #{turf.map { |r| "#{r}@#{shas.to_h[r].to_s.empty? ? '?' : shas.to_h[r].to_s[0, 7]}" }.join(', ')}"
    end
  end
end

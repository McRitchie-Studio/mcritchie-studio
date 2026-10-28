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
    # the newest completed gauntlet event, or nil. Plain `where`, so it reads on a
    # production board that predates this file.
    SNAPSHOT_RUBY = "devnet_gauntlet: r.release_events.where(step: '#{STEP}', status: 'completed')" \
                    ".order(:occurred_at).last&.slice('occurred_at', 'actor', 'metadata')".freeze

    module_function

    def required?(repo_names) = (Array(repo_names).map(&:to_s) & REPOS).any?

    # [verdict, message]. verdict is one of
    #   :not_required  the release carries no Turf repo
    #   :recorded      a completed gauntlet is on the release
    #   :waived        none is recorded and the operator passed SKIP_FLAG with words
    #   :unknown       the snapshot carried no answer (an older reader): warn, proceed
    #   :refused       none is recorded: production waits for it
    def verdict(repos:, snapshot:, waiver: nil)
      turf = Array(repos).map(&:to_s) & REPOS
      return [:not_required, nil] if turf.empty?

      unless snapshot.is_a?(Hash) && snapshot.key?(STEP)
        return [:unknown, "the release snapshot did not say whether a devnet gauntlet ran for #{turf.join(', ')}; " \
                          "confirm a green contest-rehearsal on QA before this ship goes further"]
      end

      recorded = snapshot[STEP]
      if recorded.is_a?(Hash)
        by = recorded["actor"].to_s.strip
        return [:recorded, "devnet gauntlet recorded #{recorded["occurred_at"]}#{" by #{by}" unless by.empty?} " \
                           "for #{turf.join(', ')}"]
      end

      words = waiver.to_s.strip
      unless words.empty?
        return [:waived, "NO devnet gauntlet is recorded for #{turf.join(', ')}; shipping on #{SKIP_FLAG}: \"#{words}\""]
      end

      [:refused, refusal(turf)]
    end

    def refusal(turf)
      "this release carries #{turf.join(' and ')} and has NO devnet gauntlet recorded. Re-run `bin/release prepare`, " \
        "which runs Turf Monster's contest-rehearsal on QA (docs/agents/agents/turf_monster/sops/contest-rehearsal.md) " \
        "to a green close and records it (or, for a hand-run rehearsal, POST " \
        "/api/v1/releases/current/events/#{STEP}/complete), then re-run the ship. " \
        "Only on Alex McRitchie's words: #{SKIP_FLAG} \"<his words>\"."
    end
  end
end

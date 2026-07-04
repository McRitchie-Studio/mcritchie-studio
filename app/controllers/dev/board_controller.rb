# frozen_string_literal: true

module Dev
  # Local-only board toys: spawn / advance / remove a throwaway "dev fixture" task
  # so the live /deployments board (Turbo Streams) can be demoed without real data
  # or admin-auth gymnastics. NEVER mounted in production — the routes draw only
  # when Rails.env.local? (development + test), and every action re-checks the env
  # as defense in depth. Mutations are scoped to fixtures (metadata.dev_fixture),
  # so a real task is never touched.
  class BoardController < ApplicationController
    # A local-only convenience tool — no login required (the value is skipping
    # auth gymnastics). Safe because it is gated to Rails.env.local? at both the
    # route and the action. CSRF still applies in the browser (the buttons send
    # the token); it's off in the test env as usual.
    skip_before_action :require_authentication, raise: false
    before_action :ensure_local!

    FIXTURE_MARK = "dev_fixture"
    # Whimsical titles so a spawned card reads like a real one on the board.
    SAMPLE_TITLES = [
      "Refactor the flux capacitor", "Polish the warp nacelles", "Untangle the spaghetti",
      "Feed the CI hamsters", "Rename all the things", "Debounce the kraken",
      "Caffeinate the scheduler", "Yak-shave the build pipeline"
    ].freeze

    # Spawn a fresh fixture in Designed → after_create genesis TaskEvent → the
    # broadcaster prepends the card to the Designed column live (no reload).
    def generate
      mascot = Pokemon.draw # a random mon, so the card wears a real type color
      Task.create!(
        title: SAMPLE_TITLES.sample,
        slug: "dev-fixture-#{SecureRandom.hex(3)}", # explicit + unique: sample titles repeat
        stage: "designed",
        metadata: {
          FIXTURE_MARK => true,
          "devops" => { "repositories" => ["mcritchie-studio"], "mascot" => mascot&.slug }.compact
        }
      )
      # The card animates in live via the shared LiveBoardFx (off the genesis
      # broadcast); the glow colour comes from the card's data-glow (mascot type).
      head :no_content
    end

    # Advance the newest fixture one deploy-stage (wrapping shipped → designed) →
    # after_update transition TaskEvent → the broadcaster moves the card live.
    def move
      task = latest_fixture or return head(:no_content)
      task.update!(stage: next_stage(task.stage))
      head :no_content
    end

    # Drop the newest fixture. Task#after_destroy_commit broadcasts the card removal
    # to the live board (LiveBoardFx shrinks it out + reclaims the gap).
    def delete
      task = latest_fixture or return head(:no_content)
      task.destroy!
      head :no_content
    end

    # Ship the active release (opening a throwaway one first if none is active) →
    # Release#after_commit broadcasts the swapped Next/Last modules, so the live
    # board animates the deploy with NO reload: the just-shipped release bursts into
    # the Last Release slot and the Next Release resets to its "none active" card.
    # The trigger for the release-ship e2e and the dev-tools "Ship" button.
    def ship_release
      release = Release.current || open_fixture_release
      release.update!(deployed_sha: SecureRandom.hex(20))
      release.ship!(by: "dev")
      head :no_content
    end

    # Open a fresh throwaway release with an untouched stage timeline (every
    # tracker node dark) — clears any prior fixture release first so the tracker
    # starts clean.
    def open_release
      reset_release_fixtures
      open_fixture_release
      head :no_content
    end

    # Advance the fixture release ONE stage by stamping the next blank stage in
    # Release::STAGES — the exact time-and-boolean inputs the live tracker reads —
    # so each click walks Testing → Assembling → … → Confirming → Deploying,
    # including the handoff gaps (a stamped `qa_deployed` leaves Confirming dark
    # until the next click stamps `confirming`, just like the real Avi handoff).
    # The terminal stage SHIPS (no separate confirmed-but-unshipped pause), so a
    # Last Release appears immediately. Wraps from shipped back to a fresh release.
    def advance_release
      release = current_fixture_release || open_fixture_release
      next_index = (release.current_stage_index || -1) + 1
      stage = Release::STAGE_NAMES[next_index]
      case stage
      when nil
        reset_release_fixtures
        open_fixture_release
      when "assembling"
        # The sweep frame: a member rides along so the card shows its pill. The
        # stamp itself updates the release, so the broadcast emits this frame.
        add_fixture_member(release)
        release.stamp_stage!(stage)
      when "shipped"
        # ship! stamps confirmed_at (kept if already stamped) + shipped_at itself;
        # we set the deploy sha it records.
        release.update!(deployed_sha: SecureRandom.hex(20))
        release.ship!(by: "dev")
      else
        release.stamp_stage!(stage)
      end
      head :no_content
    end

    # Clear the fixture release(s) + their member tasks → the tracker empties.
    def reset_release
      reset_release_fixtures
      head :no_content
    end

    private

    # A throwaway active release (marked so it never reads as real) carrying a random
    # mascot — only used when nothing is active, so the Ship toy still has something
    # to deploy.
    def open_fixture_release
      Release.open!.tap do |release|
        release.update!(metadata: { FIXTURE_MARK => true, "devops" => { "mascot" => Pokemon.draw&.slug }.compact })
      end
    end

    # The active fixture release, or nil (scoped to the marker — never a real one).
    def current_fixture_release
      Release.where("metadata ->> ? = 'true'", FIXTURE_MARK)
             .where(state: Release::ACTIVE_STATES)
             .order(created_at: :desc).first
    end

    # Attach a throwaway member task so the release card shows a member pill.
    def add_fixture_member(release)
      Task.create!(
        title: SAMPLE_TITLES.sample,
        slug: "dev-fixture-rel-#{SecureRandom.hex(3)}",
        stage: "assembled",
        release_slug: release.slug,
        metadata: { FIXTURE_MARK => true, "devops" => { "repositories" => ["mcritchie-studio"], "mascot" => Pokemon.draw&.slug }.compact }
      )
    end

    # Tear down every fixture release + its fixture member tasks. Scoped to the
    # marker, so a real release/task is never touched.
    def reset_release_fixtures
      Release.where("metadata ->> ? = 'true'", FIXTURE_MARK).find_each do |release|
        Task.where(release_slug: release.slug)
            .where("metadata ->> ? = 'true'", FIXTURE_MARK).destroy_all
        release.destroy!
      end
    end

    def ensure_local!
      head :forbidden unless Rails.env.local?
    end

    # Newest dev fixture, or nil. Scoped to the marker so move/delete can NEVER
    # touch a real task.
    def latest_fixture
      Task.where("metadata ->> ? = 'true'", FIXTURE_MARK).order(created_at: :desc).first
    end

    def next_stage(stage)
      zones = Task::DEPLOYMENTS_BOARD_STAGES
      zones[((zones.index(stage) || -1) + 1) % zones.size]
    end
  end
end

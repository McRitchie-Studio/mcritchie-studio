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
          "devops" => fixture_devops(mascot)
        }
      )
      # The card animates in live via the shared LiveBoardFx (off the genesis
      # broadcast); the glow colour comes from the card's data-glow (mascot type).
      head :no_content
    end

    # Advance the newest fixture ONE BEAT (wrapping shipped → designed) →
    # after_update TaskEvent → the broadcaster moves the card live.
    #
    # A beat is usually a stage, but `building` gets TWO: the second flags the
    # operator-approval request WITHOUT moving the card, so the tester can walk
    # into the WAITING APPROVAL state — the one board state that was previously
    # unreachable from these buttons. The beat after it is the payoff: submitting
    # settles the request (Task#settle_operator_approval_past_submit), so one more
    # click demonstrates the badge dropping the way it does in the real cycle.
    def move
      task = latest_fixture or return head(:no_content)
      request_fixture_approval(task) || task.update!(stage: next_stage(task.stage))
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
      # Same cadence the real deploy plays (Release::BOARD_FLIP_CADENCE), so the toy
      # demonstrates what an operator actually sees: members leaving the top of
      # Assembled one at a time, not a column emptying in one frame.
      release.ship!(by: "dev", member_pause: Release::BOARD_FLIP_CADENCE)
      head :no_content
    end

    # Re-broadcast the release modules with NOTHING changed — the spurious redraw.
    # Both cards are replaced with byte-identical HTML, which is what the live board
    # received on every CI upsert before the ReleaseFx router (DeploymentsBroadcaster
    # .ci_progress → .release_modules, ~24 per run per repo) and what it answered with
    # a pop + lift + glow + confetti on the Last Release card. Drives the e2e proof
    # that the router now answers it with silence. Sends BOTH slots on purpose: the
    # real caller no longer pushes :last, so this toy is where that path stays tested.
    def rebroadcast_release_modules
      DeploymentsBroadcaster.release_modules
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

    # Advance the visible active release ONE stage by stamping the next blank stage
    # in Release::STAGES — the exact time-and-boolean inputs the live tracker reads —
    # so each click walks Testing → Assembling → … → Confirming → Deploying,
    # including the handoff gaps (a stamped `qa_deployed` leaves Confirming dark
    # until the next click stamps `confirming`, just like the real Avi handoff).
    # The terminal stage SHIPS (no separate confirmed-but-unshipped pause), so a
    # Last Release appears immediately. If no active release exists, it opens a
    # marked fixture; if a local preview release already exists, it steps that
    # release instead of tripping the singleton active-release validation.
    def advance_release
      release = release_for_dev_advance
      next_index = (release.current_stage_index || -1) + 1
      stage = Release::STAGE_NAMES[next_index]
      # `tested` is a /deployments table stamp, not one of the 5 tracker nodes —
      # the toy skips it so a click still advances the visible pizza-tracker.
      stage = Release::STAGE_NAMES[next_index += 1] if stage == "tested"
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
        release.ship!(by: "dev", member_pause: Release::BOARD_FLIP_CADENCE)
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
      mascot = Pokemon.draw
      Release.open!.tap do |release|
        release.update!(metadata: { FIXTURE_MARK => true, "devops" => fixture_devops(mascot) })
      end
    end

    # The active fixture release, or nil (scoped to the marker — never a real one).
    def current_fixture_release
      Release.where("metadata ->> ? = 'true'", FIXTURE_MARK)
             .where(state: Release::ACTIVE_STATES)
             .order(created_at: :desc).first
    end

    def release_for_dev_advance
      current_fixture_release || Release.current || open_fixture_release
    end

    # Attach a throwaway member task so the release card shows a member pill.
    def add_fixture_member(release)
      mascot = Pokemon.draw
      Task.create!(
        title: SAMPLE_TITLES.sample,
        slug: "dev-fixture-rel-#{SecureRandom.hex(3)}",
        stage: "assembled",
        release_slug: release.slug,
        metadata: { FIXTURE_MARK => true, "devops" => fixture_devops(mascot) }
      )
    end

    def fixture_devops(mascot)
      devops = { "repositories" => ["mcritchie-studio"] }
      return devops unless mascot

      shiny = Pokemon.roll_shiny?
      devops.merge(
        "mascot" => mascot.slug,
        "mascot_shiny" => shiny,
        "mascot_color" => mascot.signature_color,
        "mascot_emoji" => mascot.status_emoji(shiny: shiny)
      ).compact
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

    # The extra `building` beat: flag the operator-approval request in place.
    # Returns nil (so the caller falls through to a normal stage move) unless the
    # fixture is sitting on `building` with no open request.
    #
    # A local_url rides along because the WAITING APPROVAL bar is only a LINK when
    # the task has one — without it the tester would render the inert notice
    # variant and the button being demoed could not be clicked.
    #
    # It is an ABSOLUTE url on LOOPBACK, not the bare path "/tasks", and that is
    # load-bearing rather than decorative: the CTA builds its hand-off through
    # LocalReviewLink.for, which parses local_url and returns nil unless it is an
    # HTTP(S) url on a loopback host (app/services/local_review_link.rb) — a bare
    # path fails the URI::HTTP check and the click would bounce to the task page.
    #
    # The host is spelled `localhost` rather than taken from request.base_url,
    # because base_url is whatever the BROWSER used to reach the board: hit this
    # stack from a phone on the LAN (or from a request spec, where it is
    # www.example.com) and a base_url-derived local_url is not loopback, so the
    # very bar being demoed would render inert. Only the port needs to come from
    # the request. Asserted, not claimed: the "LocalReviewLink will actually
    # accept" test below pins both directions — and caught exactly this when the
    # first version of this line used base_url.
    def request_fixture_approval(task)
      return nil unless task.stage == "building"
      return nil if task.waiting_for_operator_approval?

      merged = task.metadata.deep_dup
      devops = (merged["devops"] ||= {})
      devops["approval_status"] = Task::OPERATOR_APPROVAL_WAITING
      devops["local_url"] = "http://localhost#{":#{request.port}" unless request.port == 80}/tasks"
      task.update!(metadata: merged)
    end
  end
end

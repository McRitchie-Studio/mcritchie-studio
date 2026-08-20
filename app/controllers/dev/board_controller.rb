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
    # The scripted CI run the `building` CI beat plays: ten checks, one settling every
    # five seconds, and the LAST one fails — so a single click demonstrates every state
    # the meter can draw (running, passed, failed) and ends on the red the operator
    # most needs to recognise. `beat` is overridable per request so a test can run the
    # whole script without sleeping through it.
    DEV_CI_CHECK_COUNT = 10
    DEV_CI_BEAT_SECONDS = 5
    DEV_CI_REPO = "McRitchie-Studio/mcritchie-studio"
    DEV_CI_CHECK_NAMES = [
      "lint", "rubocop", "unit", "models", "controllers", "helpers",
      "integration", "system", "assets", "playwright"
    ].freeze
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
    # A beat is usually a stage, but `building` gets THREE, because that is where the
    # real cycle now spends its most interesting minutes:
    #
    #   1. flag the operator-approval request WITHOUT moving the card, so the tester
    #      can walk into the WAITING APPROVAL state;
    #   2. RUN CI — open a PR-shaped run of DEV_CI_CHECK_COUNT checks and settle one
    #      every DEV_CI_BEAT_SECONDS, mirroring `bin/ship`, which opens the PR and
    #      then waits on CI with the task still on the builder's desk. This is the
    #      beat the card's CI meter exists for, and it was previously unreachable
    #      from these buttons: the marks flip and the clock ticks live;
    #   3. submit — which settles the approval request
    #      (Task#settle_operator_approval_past_submit) and freezes the meter's clock
    #      to the run's measured duration.
    #
    # Beats 1 and 2 return before the stage move, so one click = one beat.
    def move
      task = latest_fixture or return head(:no_content)
      request_fixture_approval(task) || run_fixture_ci(task) || task.update!(stage: next_stage(task.stage))
      head :no_content
    end

    # Drop the newest fixture. Task#after_destroy_commit broadcasts the card removal
    # to the live board (LiveBoardFx shrinks it out + reclaims the gap).
    def delete
      task = latest_fixture or return head(:no_content)
      clear_fixture_ci(task)
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
      # The ladder row is a live board surface too, and these toys exist precisely so
      # the operator can watch the board move without real data.
      DeploymentsBroadcaster.app_ladder
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
    # BEAT 2 of `building`: play a whole CI run against this fixture, live.
    #
    # Returns nil (so `move` falls through to the next beat) unless the fixture is
    # sitting on `building` with the approval request already open and NO run of its
    # own yet — which makes the three building beats deterministic in either order of
    # clicking, and makes a second click during a run a no-op rather than a re-run.
    #
    # What it does, in the shape the real pipeline does it: stamps the task with the
    # PR url + branch the meter reads (so the card's label shows a real "PR: <n>"),
    # opens a GithubWorkflowRun, queues DEV_CI_CHECK_COUNT CiCheckJob rows — every one
    # of those writes broadcasts on its own after_commit, so the meter appears full of
    # spinners — then settles them one per beat. The LAST check fails, so the run ends
    # red with its ✗ pushed to the left of the rail.
    #
    # The pacing uses Release::BeatClock, the same monotonic cadence primitive
    # `Release#ship!` uses for its board flips, and sleeps INLINE in the request the
    # way ship_release does: this is a local-only toy, the whole point is to watch the
    # board move while it runs, and the Advance button stays disabled meanwhile (its
    # Alpine `busy` flag), which is exactly the right affordance mid-run.
    def run_fixture_ci(task)
      return nil unless task.stage == "building"
      return nil unless task.waiting_for_operator_approval?

      branch = "feat/#{task.slug}"
      return nil if GithubWorkflowRun.for_repo(DEV_CI_REPO).where(head_branch: branch).exists?

      sha = "devfixture-#{SecureRandom.hex(8)}"
      stamp_fixture_pr(task, branch)
      open_fixture_ci_run(branch, sha)
      jobs = queue_fixture_ci_jobs(branch, sha)
      settle_fixture_ci_jobs(jobs)
      true
    end

    # The devops fields the meter reads: the PR url it labels itself with and links
    # to, and the branch the reader resolves the run from.
    def stamp_fixture_pr(task, branch)
      merged = task.metadata.deep_dup
      devops = (merged["devops"] ||= {})
      devops["branch"] = branch
      devops["repositories"] = ["mcritchie-studio"]
      devops["pr_url"] ||= "https://github.com/McRitchie-Studio/mcritchie-studio/pull/#{rand(100..999)}"
      task.update!(metadata: merged)
    end

    def open_fixture_ci_run(branch, sha)
      GithubWorkflowRun.create!(
        repo: DEV_CI_REPO, workflow_name: GithubWorkflowRun::CI_WORKFLOW,
        run_id: SecureRandom.random_number(10**12), status: "in_progress",
        head_branch: branch, head_sha: sha, run_started_at: Time.current,
        html_url: "https://github.com/McRitchie-Studio/mcritchie-studio/actions"
      )
    end

    # Every check QUEUED at once — the meter's first frame is a full row of spinners
    # and a clock already ticking, which is what a real run looks like the moment its
    # jobs are scheduled.
    def queue_fixture_ci_jobs(branch, sha)
      started = Time.current
      DEV_CI_CHECK_NAMES.first(DEV_CI_CHECK_COUNT).map do |name|
        CiCheckJob.create!(
          repo: DEV_CI_REPO, job_id: SecureRandom.random_number(10**12),
          head_sha: sha, head_branch: branch, workflow_name: GithubWorkflowRun::CI_WORKFLOW,
          name: name, status: "queued", started_at: started
        )
      end
    end

    # One check settles per beat, the last one RED. Each save broadcasts a morph of
    # just that card's meter slot, so the marks migrate (green right, the final red
    # left) with no reload.
    def settle_fixture_ci_jobs(jobs)
      clock = Release::BeatClock.new(fixture_ci_beat_seconds)
      jobs.each_with_index do |job, index|
        clock.wait_for_beat(index + 1) { |remaining| sleep(remaining) }
        last = index == jobs.size - 1
        job.update!(status: "completed", conclusion: last ? "failure" : "success",
                    completed_at: Time.current)
      end
    end

    # Seconds between check settlements — DEV_CI_BEAT_SECONDS, or the `beat` param so
    # a test can play the whole script instantly. Local-only endpoint, so a request
    # parameter is a safe seam here.
    def fixture_ci_beat_seconds
      params.key?(:beat) ? params[:beat].to_f : DEV_CI_BEAT_SECONDS
    end

    # Drop a fixture's CI rows with the fixture itself, so the next lap around the
    # board opens a fresh run instead of inheriting a settled one.
    def clear_fixture_ci(task)
      branch = task.devops_field("branch").to_s
      return if branch.blank?

      GithubWorkflowRun.for_repo(DEV_CI_REPO).where(head_branch: branch).delete_all
      CiCheckJob.for_repo(DEV_CI_REPO).where(head_branch: branch).delete_all
    end

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

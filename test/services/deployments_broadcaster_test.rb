require "test_helper"
require "minitest/mock"
# Rails 8.1 defers turbo-rails' on_load(:action_cable) hook, which is what
# normally requires this helper, so load it explicitly before the include below.
require "turbo/broadcastable/test_helper"

# DeploymentsBroadcaster: turns a TaskEvent into a Turbo Stream that patches the
# /deployments board live — a replace (intent / same column), a remove+prepend
# (cross-column move), a prepend (new task), or a remove (left the board).
# capture_turbo_stream_broadcasts returns parsed <turbo-stream> Nokogiri nodes.
class DeploymentsBroadcasterTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
  end

  REVIEWERS = [{ "slug" => "carl", "weight" => "primary" }, { "slug" => "shannon", "weight" => "light" }].freeze

  # A task that actually walked designed→building→submitted with an actor, so its
  # crew entries aren't empty and the deploy card renders its crew + intent ticker.
  def built_submitted_task
    task = Task.create!(title: "Broadcaster sample task", stage: "designed")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")
    task.update!(stage: "submitted")
    task
  ensure
    Current.reset
  end

  # --- [unit] the right Turbo action per event --------------------------------

  test "an intent REPLACES the card in place, with the live ticker" do
    task = built_submitted_task
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(intent) }

    assert_equal 1, streams.size
    assert_equal "replace", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
    assert_includes streams.first.to_html, "crew-live", "the re-rendered card shows the in-progress ticker"
  end

  test "[integration] approval_change REPLACES the card in place so the WAITING bar pops live" do
    task = built_submitted_task
    task.update!(stage: "building") # a live board card the operator can approve
    md = task.metadata.deep_dup
    (md["devops"] ||= {})["approval_status"] = "waiting"
    task.update!(metadata: md)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.approval_change(task) }

    assert_equal 1, streams.size
    assert_equal "replace", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
    assert_includes streams.first.to_html, "WAITING APPROVAL", "the re-rendered card carries the approval bar"
  end

  # THE GAP THESE PIN (/tasks/broadcast-block-to-board): blocking broadcast NOTHING.
  # Task#block! is a bare update! that records no TaskEvent, and DeploymentsBroadcaster
  # is driven by .task_event — so a blocked card sat unchanged on every open board until
  # something unrelated forced a re-render. Three e2e specs asserted the live behaviour
  # and had been quarantined as "rotted tests"; the tests were right and the feature was
  # missing.
  test "[integration] blocking a task broadcasts its card, tone and all" do
    task = built_submitted_task
    task.update!(stage: "building")

    streams = capture_turbo_stream_broadcasts("deployments") { task.block!(by: "avi", kind: "rework") }

    # remove+prepend, NOT replace — see .block_change. A replace can only update a card
    # the viewer already has; the prepend is what puts a MISSING one back on the board.
    assert(streams.any? { |st| st["action"] == "remove" && st["target"] == "card-#{task.slug}" },
           "removes the stale card")
    prepended = streams.find { |st| st["action"] == "prepend" }
    assert prepended, "prepends a fresh card"
    assert_equal "dropzone-building", prepended["target"],
                 "a block is an ATTRIBUTE — the card stays in Building, it does not move columns"
    # Assert the card carries the BLOCK, not merely that some card was sent: the whole
    # point is the operator seeing the needs-attention tone arrive.
    assert_includes prepended.to_html, "blocked",
                    "the re-rendered card carries its blocked tone (data-glow)"
  end

  test "[integration] unblocking broadcasts too, so the tone clears without a refresh" do
    task = built_submitted_task
    task.update!(stage: "building")
    task.block!(by: "avi", kind: "rework")

    streams = capture_turbo_stream_broadcasts("deployments") { task.unblock! }

    # One guard covers both directions because blocked_at is the column that moves each
    # way. A clear that never reached the board would strand a red card forever.
    assert(streams.any? { |st| st["action"] == "prepend" && st["target"] == "dropzone-building" },
           "the cleared card is re-seated in Building")
  end

  test "a cross-column stage move REMOVES the old card and PREPENDS a fresh one" do
    task = built_submitted_task
    Current.task_event_reviewers = REVIEWERS
    task.update!(stage: "reviewed")
    Current.reset
    event = task.task_events.transitions.last # submitted → reviewed

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 2, streams.size
    assert(streams.any? { |s| s["action"] == "remove" && s["target"] == "card-#{task.slug}" }, "removes the old card")
    assert(streams.any? { |s| s["action"] == "prepend" && s["target"] == "dropzone-reviewed" }, "prepends to the new column")
  end

  test "a brand-new task (genesis) PREPENDS to the Designed column" do
    task = Task.create!(title: "Fresh genesis board task", stage: "designed")
    genesis = task.task_events.transitions.first # nil → designed

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(genesis) }

    assert_equal 1, streams.size
    assert_equal "prepend", streams.first["action"]
    assert_equal "dropzone-designed", streams.first["target"]
  end

  test "a task leaving the board (→ archived) REMOVES its card with a mist exit hint" do
    task = built_submitted_task
    task.update!(stage: "archived")
    event = task.task_events.transitions.last

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 1, streams.size
    assert_equal "remove", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
    assert_equal "archive", streams.first["data-exit-action"]
  end

  test "a block (submitted→building) REMOVES then PREPENDS into the Building column" do
    # A block is a `building` attribute now — block! moves submitted→building,
    # which the board treats as a cross-column move into Building.
    task = Task.create!(title: "Blocked column re-tint task", stage: "submitted")
    task.block!(by: "avi", kind: "rework")
    event = task.task_events.transitions.last # submitted → building

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 2, streams.size
    assert(streams.any? { |s| s["action"] == "remove" && s["target"] == "card-#{task.slug}" }, "removes any stale visible card")
    assert(streams.any? { |s| s["action"] == "prepend" && s["target"] == "dropzone-building" }, "prepends blocked cards into Building")
  end

  test "a block (submitted→building) sends one ordered websocket payload" do
    task = Task.create!(title: "Blocked websocket race task", stage: "submitted")
    task.block!(by: "avi", kind: "rework")
    event = task.task_events.transitions.last # submitted → building
    broadcasts = []

    Turbo::StreamsChannel.stub(:broadcast_stream_to, ->(*streamables, content:) {
      broadcasts << { streamables:, content: content.to_s }
    }) do
      DeploymentsBroadcaster.task_event(event)
    end

    assert_equal 1, broadcasts.size
    assert_equal ["deployments"], broadcasts.first.fetch(:streamables)
    streams = Nokogiri::HTML5.fragment(broadcasts.first.fetch(:content)).css("turbo-stream")
    assert_equal %w[remove prepend], streams.map { |stream| stream["action"] }
    assert_equal "card-#{task.slug}", streams.first["target"]
    assert_equal "dropzone-building", streams[1]["target"]
  end

  test "an assembled broadcast keeps both mascot type colors in the gradient" do
    Studio::Enumeral.create!(category: "pokemon_type", key: "fire", color: "#EE8130", rank: 900)
    Studio::Enumeral.create!(category: "pokemon_type", key: "flying", color: "#A98FF3", rank: 200)
    Pokemon.create!(dex: 6, name: "Charizard", slug: "charizard", types: %w[fire flying],
                    primary_type: "fire", generation: 1)
    task = Task.create!(title: "Live assembled gradient task", stage: "reviewed",
                        metadata: { "devops" => { "mascot" => "charizard", "mascot_color" => "#EE8130" } })
    task.update!(stage: "assembled")
    event = task.task_events.transitions.last

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    card = streams.find { |stream| stream["action"] == "prepend" }
    assert_includes card.to_html, "--task-card-glow-color-a: #EE8130"
    assert_includes card.to_html, "--task-card-glow-color-b: #A98FF3"
  end

  # --- [unit] the hook + the SEV-1 guard --------------------------------------

  test "the after-commit hook skips backfilled (bulk history) events" do
    task = built_submitted_task
    backfilled = task.task_events.create!(from_stage: "submitted", to_stage: "reviewed",
                                          occurred_at: Time.current, metadata: { "backfilled" => true })
    streams = capture_turbo_stream_broadcasts("deployments") { backfilled.send(:broadcast_to_deployments_board) }
    assert_empty streams
  end

  test "a ScriptError from the broadcast never escapes the task write (SEV-1 guard via safe_broadcast)" do
    task = built_submitted_task
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*_a, **_k) { raise Gem::LoadError, "redis not in bundle" }) do
      assert_nothing_raised do
        assert_nil DeploymentsBroadcaster.task_event(intent)
      end
    end
  end

  # --- delete: a destroy fires no TaskEvent, so removal is broadcast separately ---

  test "[unit] task_removed broadcasts a card remove to the deployments stream" do
    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_removed("some-slug") }
    assert_equal 1, streams.size
    assert_equal "remove", streams.first["action"]
    assert_equal "card-some-slug", streams.first["target"]
    assert_equal "delete", streams.first["data-exit-action"]
  end

  test "[unit] task_removed is guarded — a dead cable can't break the destroy" do
    Turbo::StreamsChannel.stub(:broadcast_remove_to, ->(*_a, **_k) { raise Gem::LoadError, "redis not in bundle" }) do
      assert_nothing_raised { DeploymentsBroadcaster.task_removed("some-slug") }
    end
  end

  test "[integration] destroying a task broadcasts the card removal to the live board" do
    task = Task.create!(title: "Doomed board task here", stage: "designed")
    streams = capture_turbo_stream_broadcasts("deployments") { task.send(:broadcast_removal_to_deployments_board) }
    assert_equal 1, streams.size
    assert_equal "remove", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
  end

  test "[integration] Task wires the removal broadcast on after_destroy_commit" do
    assert Task._commit_callbacks.any? { |c| c.filter == :broadcast_removal_to_deployments_board },
      "Task must broadcast the card removal after a destroy commits"
  end

  # --- release modules: the Next/Last cards live-update on a release change ----

  test "[unit] release_modules REPLACES both the current-release and last-release slots" do
    shipped = Release.open!
    shipped.ship!          # terminal → frees the singleton AND becomes last_shipped
    Release.open!          # a fresh active release fills the current slot

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.release_modules }

    assert_equal %w[current-release last-release], streams.map { |s| s["target"] }.sort
    streams.each { |s| assert_equal "replace", s["action"] }
    assert_includes streams.find { |s| s["target"] == "last-release" }.to_html, shipped.slug
  end

  test "[integration] after a ship, release_modules resets Next to empty + swaps Last to the just-shipped" do
    active = Release.open!
    active.ship!(by: "avi") # now shipped: Release.current is nil, last_shipped == active

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.release_modules }

    current = streams.find { |s| s["target"] == "current-release" }
    last = streams.find { |s| s["target"] == "last-release" }
    assert_includes current.to_html, "none active", "Next Release resets to its fresh empty card"
    assert_includes last.to_html, active.slug, "Last Release wears the just-shipped release"
  end

  test "[integration] release_modules carries the per-repo lanes tracker for the active release" do
    active = Release.open!
    active.add(Task.create!(title: "Next release lane member", stage: "reviewed",
                            metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }))

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.release_modules }
    current = streams.find { |s| s["target"] == "current-release" }

    assert current, "release_modules replaces the current-release slot"
    assert_includes current.to_html, %(data-test="release-lanes"), "the morph carries the new per-repo lanes tracker"
    assert_includes current.to_html, %(data-repo="mcritchie-studio"), "the member's own lane rides along"
  end

  # --- the fx router seam: WHY a broadcast fired, declared instead of inferred ----
  #
  # The operator-visible bug these guard: every finished assembling CI test flashed
  # the Last Release card (pop + lift + glow + confetti). .ci_progress re-broadcast
  # BOTH release cards on every CI upsert, Release.last_shipped cannot change on a CI
  # tick, so the client got byte-identical HTML and — having no declared reason and no
  # signature to diff — celebrated it.

  test "[unit] release_modules declares the fx kind on the last-release stream" do
    Release.open!.ship!

    streams = capture_turbo_stream_broadcasts("deployments") do
      DeploymentsBroadcaster.release_modules(fx: "deploy.landed")
    end

    last = streams.find { |s| s["target"] == "last-release" }
    assert_equal "replace", last["action"], "the declared kind rides a plain replace, not a morph"
    assert_equal "deploy.landed", last["data-fx"], "the router reads the reason off the stream element"
  end

  test "[unit] release_modules with no fx declares nothing rather than an empty attribute" do
    Release.open!.ship!

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.release_modules }

    last = streams.find { |s| s["target"] == "last-release" }
    assert_nil last["data-fx"], "an undeclared broadcast carries no kind — the router then falls to the signature"
  end

  test "[unit] release_modules honours slots — :current alone pushes no last-release" do
    Release.open!.ship!
    Release.open!

    streams = capture_turbo_stream_broadcasts("deployments") do
      DeploymentsBroadcaster.release_modules(slots: [:current])
    end

    assert_equal %w[current-release], streams.map { |s| s["target"] },
                 "a caller that cannot change the Last card does not push it"
  end

  test "[unit] a CI tick refreshes ONLY the Next Release card, declared silent" do
    rel = Release.open!
    rel.add(Task.create!(title: "Assembling CI member", stage: "reviewed",
                         metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }))
    job = seed_ci(repo: "McRitchie-Studio/mcritchie-studio", branch: Release::BRANCH,
                  sha: "ci-tick-sha", passed: 3, pending: 5)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(job) }

    refute streams.any? { |s| s["target"] == "last-release" },
           "a finished assembling test must not redraw the Last Release card at all"
    assert streams.any? { |s| s["target"] == "current-release" }, "the Next Release card still ticks"
  end

  test "[unit] a silent kind still rides the last-release stream when a caller sends that slot" do
    Release.open!.ship!

    # .ci_progress no longer sends :last, so this is the declaration's OTHER job:
    # keeping the slot silent if some future caller wires it back up. The kind must
    # survive to the client for the router's SILENT_KINDS check to have anything to
    # read — a declaration only the sender knows about protects nothing.
    streams = capture_turbo_stream_broadcasts("deployments") do
      DeploymentsBroadcaster.release_modules(fx: "ci.progress")
    end

    assert_equal "ci.progress", streams.find { |s| s["target"] == "last-release" }["data-fx"]
  end

  test "[integration] a ship declares deploy.landed; an ordinary save does not" do
    release = Release.open!

    shipped = capture_turbo_stream_broadcasts("deployments") { release.ship!(by: "avi") }
    assert_equal "deploy.landed", shipped.select { |s| s["target"] == "last-release" }.last["data-fx"],
                 "the one transition that puts a NEW release in the Last slot says so"

    saved = capture_turbo_stream_broadcasts("deployments") { release.update!(qa_url: "https://qa.example.test") }
    assert_equal "release.saved", saved.select { |s| s["target"] == "last-release" }.last["data-fx"],
                 "every other save declares a kind no handler claims — the signature decides"
  end

  test "[integration] Release wires the module broadcast on after_commit" do
    assert Release._commit_callbacks.any? { |c| c.filter == :broadcast_release_modules },
      "Release must broadcast the live release modules after a commit"
  end

  test "[unit] release_modules is guarded — a dead cable can't break the release write" do
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*_a, **_k) { raise Gem::LoadError, "redis not in bundle" }) do
      assert_nothing_raised { assert_nil DeploymentsBroadcaster.release_modules }
    end
  end

  # --- block tone: the single-card render derives ever_blocked from the loaded
  #     activities (no per-card ever_blocked? query) so the tri-state tone holds --

  # The root card <div>'s class list, pulled from the broadcast card so a tone
  # assertion sees ONLY the card's own tone class — not a footer button's
  # hover:bg-* utility (every card carries hover:bg-amber-50 / hover:bg-red-50).
  def broadcast_card_class(stream, slug)
    stream.to_html[/<div id="card-#{Regexp.escape(slug)}"[^>]*\bclass="([^"]*)"/, 1].to_s
  end

  test "[integration] a cleared block broadcasts the amber re-review tone (ever_blocked derived from the loaded activities)" do
    task = built_submitted_task
    # A resolved QA block: it WAS blocked (a qa_feedback), the block is cleared (a
    # resolves_feedback handoff), and it sits back in `submitted` — so the derived
    # ever_blocked is true, unresolved is false, and the card wears amber.
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "please fix Y")
    Activity.create!(task_slug: task.slug, activity_type: "handoff", description: "fixed Y",
                     metadata: { "resolves_feedback" => true })
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(intent) }

    tone = broadcast_card_class(streams.first, task.slug)
    assert_includes tone, "bg-amber-50", "a qa_feedback in the loaded set → ever_blocked=true → amber re-review tone"
    assert_not_includes tone, "bg-red-50", "a cleared (resolved) block is amber, not red"
    assert_not_includes tone, "bg-surface", "a cleared block is not the plain tone"
    # The RE-REVIEW badge was dropped as redundant — the amber tone above carries it.
    assert_not_includes streams.first.to_html, "RE-REVIEW", "the badge is gone; the amber tone carries re-review"
  end

  test "[integration] a never-blocked card broadcasts the plain tone (ever_blocked derived false)" do
    task = built_submitted_task # no qa_feedback in its activities
    intent = task.record_intent_event(to_stage: "reviewed", reviewers: REVIEWERS)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(intent) }

    tone = broadcast_card_class(streams.first, task.slug)
    assert_includes tone, "bg-surface", "no qa_feedback in the loaded set → ever_blocked=false → plain tone"
    assert_not_includes tone, "bg-amber-50", "a never-blocked card is plain, not amber"
    assert_not_includes tone, "bg-red-50", "a never-blocked card is plain, not red"
  end

  # --- live CI progress: a workflow_job push morphs just the bar slot ----------

  def seed_ci(repo:, branch:, sha:, passed:, pending:, workflow: "CI")
    GithubWorkflowRun.create!(repo: repo, workflow_name: workflow, run_id: SecureRandom.random_number(10**12),
                              status: "in_progress", head_branch: branch, head_sha: sha, run_started_at: Time.current)
    id = SecureRandom.random_number(10**12)
    passed.times  { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: workflow, status: "completed", conclusion: "success") }
    pending.times { CiCheckJob.create!(repo: repo, job_id: (id += 1), head_sha: sha, head_branch: branch, workflow_name: workflow, status: "in_progress") }
    CiCheckJob.new(repo: repo, job_id: id + 1, head_sha: sha, head_branch: branch, workflow_name: workflow, status: "completed", conclusion: "success")
  end

  test "[integration] ci_progress morph-replaces the affected task's bar slot with fresh counts" do
    repo = "McRitchie-Studio/mcritchie-studio"
    task = Task.create!(title: "Live CI bar task", stage: "submitted",
                        metadata: { "devops" => { "branch" => "feat/live-bar", "repositories" => ["mcritchie-studio"],
                                                  "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/5" } })
    job = seed_ci(repo: repo, branch: "feat/live-bar", sha: "live-bar-sha", passed: 5, pending: 3)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(job) }

    assert_equal 1, streams.size
    assert_equal "replace", streams.first["action"]
    assert_equal "morph", streams.first["method"], "morph animates the fill width instead of snapping"
    assert_equal "ci-progress-#{task.slug}", streams.first["target"]
    # 8 checks -> 8 marks inside the rail, and the live morph keeps the meter a
    # new-tab link to the task's PR.
    html = streams.first.to_html
    assert_includes html, "ci-progress-meter", "the slot re-renders the live meter"
    assert_equal 8, html.scan("data-test=\"ci-check-symbol\"").size
    assert_includes html, "href=\"https://github.com/McRitchie-Studio/mcritchie-studio/pull/5\""
    assert_includes html, "target=\"_blank\""
    # The morph carries the SAME locals the card render passes — a dropped `label`
    # would silently rewrite "PR: 5" back to a bare "CI" on the first live tick.
    assert_includes html, ">PR: 5<", "the live morph keeps the PR-number label"
  end

  test "[integration] ci_progress refreshes the Next Release card for a member repo's release-branch job" do
    rel = Release.open! # the active candidate → Release.current
    rel.add(Task.create!(title: "Hub release CI member", stage: "reviewed",
                         metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }))
    job = seed_ci(repo: "McRitchie-Studio/mcritchie-studio", branch: Release::BRANCH, sha: "rel-live-sha", passed: 8, pending: 0)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(job) }

    # The per-repo G3 slots are now each lane's Assembling meter, so a member's CI push
    # refreshes the whole Next Release card (the lane updates in place).
    current = streams.find { |s| s["target"] == "current-release" }
    assert current, "the release-branch job refreshes the Next Release card"
    assert_includes current.to_html, %(data-repo="mcritchie-studio"), "the member's lane is in the morphed card"
    assert_includes current.to_html, %(data-phase="assembling"), "with its Assembling meter"
  end

  # REBASED onto `release` 2026-08-30 (/tasks/gem-track-reads-main). This seeded the
  # job on `main` and said "a gem's verdict is Engine CI on MAIN" — the same false
  # premise Ci::ProgressReader carried. studio-engine is a THREE-RUNG gem: the sweep
  # pushes the candidate onto `release`, and `main` only takes it at G4 ship. The
  # concern is unchanged — a gem member's OWN workflow fans out to the Next Release
  # card — but it must fan out on the branch that repo's track actually reads, so the
  # negative half is asserted here rather than left implied.
  test "[integration] ci_progress live-updates the card for a GEM member's Engine CI job" do
    rel = Release.open! # active candidate → Release.current
    rel.add(Task.create!(title: "Studio engine gem member", stage: "reviewed",
                         metadata: { "devops" => { "repositories" => ["studio-engine"] } }))
    job = seed_ci(repo: "McRitchie-Studio/studio-engine", branch: Release::BRANCH,
                  sha: "engine-live-sha", passed: 1, pending: 0, workflow: "Engine CI")

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(job) }

    current = streams.find { |s| s["target"] == "current-release" }
    assert current, "a gem member's Engine CI job refreshes the Next Release card"
    assert_includes current.to_html, %(data-repo="studio-engine"), "the gem's lane rides along"

    # The SHIP lane, not the candidate lane: a three-rung gem's `main` run describes the
    # release that already went out, so it must not morph the Next Release card.
    shipped = seed_ci(repo: "McRitchie-Studio/studio-engine", branch: "main",
                      sha: "engine-shipped-sha", passed: 1, pending: 0, workflow: "Engine CI")
    after = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(shipped) }
    assert_nil after.find { |s| s["target"] == "current-release" },
               "an already-shipped commit's CI must not redraw the candidate's card"
  end

  test "[integration] ci_progress does NOT refresh the release card for a non-member repo's release push" do
    Release.open! # active, but with NO members
    job = seed_ci(repo: "McRitchie-Studio/turf-monster", branch: Release::BRANCH, sha: "orphan-sha", passed: 4, pending: 0)

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(job) }

    assert_nil streams.find { |s| s["target"] == "current-release" },
               "a repo that is not a release member fires no Next Release refresh"
  end

  test "[integration] ci_progress with no eligible task or release broadcasts nothing" do
    job = CiCheckJob.new(repo: "McRitchie-Studio/mcritchie-studio", job_id: 1, head_sha: "orphan-sha",
                         head_branch: "feat/nobody", workflow_name: "CI", status: "queued")
    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.ci_progress(job) }
    assert_empty streams
  end

  test "[integration] CiCheckJob wires the live CI broadcast on after_commit" do
    assert CiCheckJob._commit_callbacks.any? { |c| c.filter == :broadcast_ci_progress },
      "CiCheckJob must push the live CI bar after a commit"
  end

  test "[unit] ci_progress is guarded — a dead cable can't break the ingest write" do
    job = CiCheckJob.new(repo: "McRitchie-Studio/mcritchie-studio", job_id: 1, head_sha: "s",
                         head_branch: Release::BRANCH, workflow_name: "CI", status: "queued")
    Release.open!
    Turbo::StreamsChannel.stub(:broadcast_stream_to, ->(*_a, **_k) { raise Gem::LoadError, "redis not in bundle" }) do
      assert_nothing_raised { assert_nil DeploymentsBroadcaster.ci_progress(job) }
    end
  end

end

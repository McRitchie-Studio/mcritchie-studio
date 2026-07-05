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

  test "a task leaving the board (→ archived) REMOVES its card" do
    task = built_submitted_task
    task.update!(stage: "archived")
    event = task.task_events.transitions.last

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 1, streams.size
    assert_equal "remove", streams.first["action"]
    assert_equal "card-#{task.slug}", streams.first["target"]
    assert_equal "archive", streams.first["data-exit-action"]
  end

  test "a building→blocked transition REMOVES then PREPENDS into the Building column" do
    task = Task.create!(title: "Blocked column re-tint task", stage: "designed")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")
    Current.reset
    task.update!(stage: "blocked")
    event = task.task_events.transitions.last # building → blocked

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.task_event(event) }

    assert_equal 2, streams.size
    assert(streams.any? { |s| s["action"] == "remove" && s["target"] == "card-#{task.slug}" }, "removes any stale visible card")
    assert(streams.any? { |s| s["action"] == "prepend" && s["target"] == "dropzone-building" }, "prepends blocked cards into Building")
  end

  test "a building→blocked transition sends one ordered websocket payload" do
    task = Task.create!(title: "Blocked websocket race task", stage: "designed")
    Current.task_event_actor = "carl"
    task.update!(stage: "building")
    Current.reset
    task.update!(stage: "blocked")
    event = task.task_events.transitions.last # building → blocked
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
    assert_includes streams.first.to_html, "RE-REVIEW", "the cleared card carries the re-review badge"
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
end

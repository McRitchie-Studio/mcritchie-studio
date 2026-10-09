# frozen_string_literal: true

# Every state TaskCardComponent can show. Each preview builds its task, crew
# events and preloads in memory: nothing is saved, and the gallery takes no
# input. The preview page loads no script, so the filters and the footer
# actions are inert here.
class TaskCardComponentPreview < ViewComponent::Preview
  TypeColour = Struct.new(:key, :color, :rank, :emoji, keyword_init: true)
  TYPES = {
    "fire" => TypeColour.new(key: "fire", color: "#EE8130", rank: 900, emoji: "🔥"),
    "flying" => TypeColour.new(key: "flying", color: "#A98FF3", rank: 200, emoji: "💨"),
    "water" => TypeColour.new(key: "water", color: "#6390F0", rank: 10, emoji: "💧")
  }.freeze
  ROSTER = %w[Carl Avi Steffon Xan].freeze

  # A new task with its mascot and nobody on it.
  def designed
    card(stage: "designed", board: :build)
  end

  # Size, migration and release-conductor badges, an epic, two apps, a gem and a bug.
  def planning_badges
    card(stage: "designed", board: :build, title: "A card whose title is long enough to overflow its column",
         po_size: "xl", requires_migration: true, epic_slug: "devops-v3",
         devops: { "kind" => "bug", "shape" => "library", "requires_release_conductor" => true,
                   "repositories" => %w[mcritchie-studio turf-monster] })
  end

  # A live claim: the pulsing dot and the last durable progress.
  def building_claimed
    card(stage: "building", board: :build, devops: ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: Time.current),
         events: [transition("designed", "building", 40.minutes.ago)])
  end

  # A building card whose PR is on CI.
  def building_with_ci
    card(stage: "building", board: :build, devops: { "pr_url" => "https://github.com/acme/app/pull/11" },
         events: [transition("designed", "building", 2.hours.ago)],
         ci_progress: Ci::CheckProgress.new(passed: 3, failed: 0, pending: 2, sha: "preview-head"))
  end

  # A rework block: the full red card and the blocker's own words.
  def blocked_rework
    card(stage: "building", board: :build, blocked_at: 20.minutes.ago, block_kind: "rework", ever_blocked: true,
         unresolved_feedback: block_note("Spacing off on the chip", kind: "rework"))
  end

  # An escalated dependency block: the escalation countdown beside the slug.
  def blocked_escalated
    card(stage: "building", blocked_at: 5.minutes.ago, block_kind: "dependency", ever_blocked: true,
         unresolved_feedback: block_note("Escalated: which default wins", kind: "dependency", by: "avi"))
  end

  # An approval request with a local page: the amber card, the bar and the countdown.
  def waiting_approval
    card(stage: "building", board: :build, epic_slug: "devops-v3",
         devops: { "approval_status" => "waiting", "approval_requested_at" => 3.minutes.ago.iso8601,
                   "local_url" => "http://localhost:3011/tasks" })
  end

  # A bounced task whose PR head has not moved since the send-back.
  def resubmission_unaddressed
    card(stage: "building", board: :build, ever_blocked: true, resubmission_state: Task::Resubmission::UNADDRESSED)
  end

  # In the review queue with nobody on it: no glow.
  def submitted
    card(stage: "submitted", devops: { "pr_url" => "https://github.com/acme/app/pull/42" },
         events: [transition("building", "submitted", 30.minutes.ago)],
         ci_progress: Ci::CheckProgress.new(passed: 5, failed: 0, pending: 0, sha: "preview-head"))
  end

  # A reviewer is on it: the two-wedge ring in the mascot's type colours.
  def under_review
    card(stage: "submitted", mascot: dual_type_mascot, review_in_progress: true,
         events: [transition("building", "submitted", 30.minutes.ago), intent("submitted", "reviewed", "carl", 6.minutes.ago)])
  end

  # A block that was cleared, back in the queue for re-review: amber.
  def cleared_block
    card(stage: "submitted", ever_blocked: true)
  end

  # Merged onto accepted: the steady glow.
  def reviewed
    card(stage: "reviewed", events: [transition("submitted", "reviewed", 1.hour.ago, actor: "carl")])
  end

  # Held out of the next release.
  def held_from_release
    card(stage: "reviewed", devops: { "included_in_release" => "false", "repositories" => ["mcritchie-studio"] })
  end

  # Open feedback past the seam: the red tint, the stage's own border.
  def reviewed_blocked
    card(stage: "reviewed", ever_blocked: true,
         unresolved_feedback: block_note("Regression on the deploy board", kind: "rework", by: "avi"))
  end

  # On the release candidate: the two-tone glow.
  def assembled
    card(stage: "assembled", mascot: dual_type_mascot,
         events: [transition("reviewed", "assembled", 25.minutes.ago, actor: "avi")])
  end

  # In production, with its QA and production links.
  def shipped
    card(stage: "shipped", devops: { "qa_url" => "https://qa.example.test", "production_url" => "https://example.test" },
         events: [transition("assembled", "shipped", 2.hours.ago, actor: "steffon")])
  end

  # Archived: no archive action.
  def archived
    card(stage: "archived")
  end

  # The latest conversation note under the stamps.
  def with_latest_note
    note = Activity.new(activity_type: "clarification", agent_slug: "avi", created_at: 4.minutes.ago,
                        description: "Which default wins when both flags are set on the same task?")
    card(stage: "designed", board: :build, latest_activity: note, activity_count: 3)
  end

  # Logged out: the Pokémon alone.
  def soul_logged_out
    card(stage: "building", board: :build, agent_session: nil)
  end

  # A builder's studio login (issued at the task claim) beside the mascot.
  def soul_builder_logged_in
    card(stage: "building", board: :build, agent_session: studio_login("carl", "task_claim"))
  end

  # A reviewer's studio login (issued with the review claim) beside the mascot.
  def soul_reviewer_logged_in
    card(stage: "submitted", review_in_progress: true, agent_session: studio_login("avi", "review_claim"),
         events: [transition("building", "submitted", 30.minutes.ago), intent("submitted", "reviewed", "avi", 6.minutes.ago)])
  end

  private

  def card(stage:, board: :deploy, title: nil, devops: {}, events: [], mascot: single_type_mascot,
           resubmission_state: Task::Resubmission::FRESH, **given)
    task_attrs = given.slice(:po_size, :requires_migration, :epic_slug, :blocked_at, :block_kind)
    name = caller_locations(1, 1).first.label.split("#").last.humanize
    task = Task.new(title: title || "#{name} card", slug: "preview-#{name.parameterize}", stage: stage,
                    metadata: { "devops" => devops }, created_at: 3.days.ago, updated_at: 12.minutes.ago, **task_attrs)
    events.each { |event| task.task_events.build(event.merge(task_slug: task.slug)) }
    bounced = resubmission_state != Task::Resubmission::FRESH
    resubmission = Task::Resubmission.new(task: task, state: resubmission_state, bounce_count: bounced ? 1 : 0,
                                          last_bounce_at: (1.hour.ago if bounced), head_at_bounce: "029a945b",
                                          head_now: "029a945b", head_tracked: bounced)
    preloads = TaskCardComponent::Preloads.new(**{
      agents: roster, mascot: mascot, type_enumerals: TYPES, latest_activity: nil, activity_count: 0,
      unresolved_feedback: nil, ever_blocked: false, review_in_progress: false, ci_progress: nil,
      resubmission: resubmission, agent_session: nil
    }.merge(given.except(*task_attrs.keys)))
    render_with_template(template: "task_card_component_preview/card",
                         locals: { card: TaskCardComponent.new(task: task, preloads: preloads, crew_board: board) })
  end

  def roster
    ROSTER.each_with_index.map { |name, position| Agent.new(name: name, slug: name.downcase, position: position) }
  end

  def single_type_mascot
    Pokemon.new(dex: 158, name: "Totodile", slug: "totodile", types: %w[water], primary_type: "water", generation: 2)
  end

  def dual_type_mascot
    Pokemon.new(dex: 6, name: "Charizard", slug: "charizard", types: %w[fire flying], primary_type: "fire", generation: 1)
  end

  def transition(from, to, at, actor: "pokemon")
    { kind: "transition", from_stage: from, to_stage: to, actor: actor, occurred_at: at }
  end

  def intent(from, to, actor, at)
    { kind: "intent", from_stage: from, to_stage: to, actor: actor, occurred_at: at }
  end

  def block_note(summary, kind:, by: "carl")
    Activity.new(activity_type: "qa_feedback", agent_slug: by, created_at: 10.minutes.ago,
                 description: "#{summary}. The full note lives on the task page.",
                 metadata: { "summary" => summary, "kind" => kind })
  end

  def studio_login(soul, issued_by)
    AgentSession.new(soul: soul, tier: "studio", issued_by: issued_by, task_slug: "preview",
                     issued_at: 10.minutes.ago, expires_at: 23.hours.from_now)
  end
end

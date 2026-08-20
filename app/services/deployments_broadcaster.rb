# frozen_string_literal: true

# Pushes a single re-rendered board card to the /deployments board over Turbo
# Streams when a task's stage changes (a transition) or an agent starts a stage's
# work (an intent), so the board updates live without a reload.
#
# It broadcasts the SAME `tasks/_task_card` partial the board loop renders, as a
# Turbo Stream action chosen by the event:
#   intent                               → REPLACE the card in place
#   cross-column stage move              → REMOVE + PREPEND in one ordered payload
#   block/unblock (a building attribute) → REPLACE the card in place (same column)
#   brand-new task (genesis)             → PREPEND to the Designed column
#   leaves the active board (→ archived) → REMOVE
# Subscribers run `turbo_stream_from "deployments"`; Turbo patches the DOM and a
# MutationObserver on the board animates the result + refreshes the column counts.
#
# Every broadcast is wrapped in Studio::Cable.safe_broadcast so a cable/adapter
# failure can NEVER break the task write that triggered it — the SEV-1 guard, now
# shared in studio-engine (rescues StandardError AND ScriptError/Gem::LoadError).
class DeploymentsBroadcaster
  include Turbo::Streams::ActionHelper

  STREAM = "deployments"
  PARTIAL = "tasks/task_card"
  # The stable-id CI bar slot (components/_ci_progress_slot) — rendered inline by
  # the task card + Next Release card AND re-rendered here for the live morph push.
  CI_SLOT_PARTIAL = "components/ci_progress_slot"
  # The stages the deploy board shows as columns. Blocked tasks are `building`
  # tasks (a block is an attribute); `archived` (or anything off this list) means
  # the card left the board.
  BOARD_ZONES = Task::DEPLOYMENTS_BOARD_STAGES

  # Wrap the WHOLE operation (resolve + render + broadcast) in the engine's
  # safe_broadcast so nothing — not even a lookup or render error — can escape the
  # after_commit and break the task write (the SEV-1 guard, ScriptError included).
  def self.task_event(event)
    Studio::Cable.safe_broadcast { new(event).deliver }
  end

  # A task was destroyed — drop its card from the live board for every viewer. A
  # `destroy` fires no TaskEvent (so #task_event never runs), hence this separate
  # entry point, called from Task's after_destroy_commit. Guarded like the rest.
  def self.task_removed(slug)
    Studio::Cable.safe_broadcast do
      Turbo::StreamsChannel.broadcast_stream_to(
        STREAM,
        content: ApplicationController.helpers.turbo_stream_action_tag(
          :remove,
          target: "card-#{slug}",
          data: { exit_action: "delete" }
        )
      )
    end
  end

  # Re-render the Next + Last release modules to every /deployments viewer after a
  # release state change (open / assemble / ship / abandon, or a mascot stamp), so
  # the cards reflect Release.current / Release.last_shipped with no reload. Two
  # REPLACE actions targeting the stable #current-release / #last-release slots; the
  # board's LiveBoardFx flashes each swapped slot (a subtle glow on Next, a
  # celebratory burst on the just-shipped Last). Computed fresh from the singleton —
  # on a ship, Release.current is nil so Next re-renders its "none active" empty
  # card. Called from Release#after_save_commit and guarded by safe_broadcast so a
  # cable failure can NEVER break the release write that triggered it (SEV-1 guard).
  # `fx` is the REASON this fired, declared to the client rather than left for it to
  # infer. It rides the #last-release stream as data-fx and the ReleaseFx router reads
  # it (see tasks/_release_fx_router): a kind the router lists as silent short-circuits
  # to no animation; anything else is a hint its handlers may consult. Declaring the
  # reason is the fix for a client that had to GUESS one — see `slots` below.
  #
  # `slots` is the second half of that fix. Not every caller can move both cards, and a
  # caller that pushes a card it cannot have changed is asking the client to tell a
  # redraw from an event with no evidence. .ci_progress fires on every CI upsert
  # (queued AND in_progress AND completed, ~24 per run per repo) and CANNOT change
  # Release.last_shipped, so it pushes :current alone. The router's default-silence
  # already makes the extra push harmless; not sending it makes it absent, and the two
  # together are why a finished assembling test no longer flashes the Last Release card.
  RELEASE_SLOTS = %i[current last].freeze

  # Push the refreshed APP LADDER ROW to every /deployments viewer.
  #
  # The row reports per-repo CI verdicts and per-rung parked counts, so it moves for
  # the same reasons the release modules do — a release opening, advancing, shipping
  # or resetting re-stamps `merged` across its members, and a CI upsert changes a
  # rung's verdict. Without this it was the one live surface on the board with no
  # broadcast: the dev deploy tools moved every other card and left this row stale
  # until a manual reload, which is exactly how the gap was found.
  #
  # Wrapped in the engine's safe_broadcast SEV-1 guard like every sibling here, so a
  # cable failure can never break the write that triggered it. Computed fresh from
  # Ci::AppLadder rather than passed in — the caller knows something changed, not what
  # the row should now say.
  def self.app_ladder
    Studio::Cable.safe_broadcast do
      Turbo::StreamsChannel.broadcast_replace_to(
        STREAM, target: "app-ladder-row",
        partial: "tasks/app_ladder_row", locals: { cards: Ci::AppLadder.build }
      )
    end
  end

  def self.release_modules(fx: nil, slots: RELEASE_SLOTS)
    Studio::Cable.safe_broadcast do
      if slots.include?(:current)
        Turbo::StreamsChannel.broadcast_replace_to(
          STREAM, target: "current-release",
          partial: "tasks/current_release", locals: { release: Release.current }
        )
      end

      if slots.include?(:last)
        rendered = ApplicationController.render(
          partial: "tasks/last_release", formats: [:html],
          locals: { release: Release.last_shipped }
        )
        Turbo::StreamsChannel.broadcast_stream_to(
          STREAM,
          content: ApplicationController.helpers.turbo_stream_action_tag(
            :replace, target: "last-release", template: rendered, data: { fx: fx }.compact
          )
        )
      end
    end
  end

  # A CI check job was upserted (CiCheckJob after_commit) — push the refreshed CI
  # progress bar to the affected task card + the Next Release card so the board ticks
  # up with NO reload. Only the tiny bar SLOT swaps — a MORPH, so the fill width
  # animates the tick and the card never flashes or loses Alpine state, even across a
  # run's ~24 workflow_job events. Mirrors .github_actions: a dedicated stable slot
  # replaced with a freshly-computed partial, wrapped in the safe_broadcast SEV-1
  # guard so a cable failure can never break the ingest write. The fresh progress is
  # read the SAME way the page render reads it (Ci::ProgressReader, live-first), so a
  # push and a reload always agree.
  def self.ci_progress(job)
    return if job.head_branch.blank? || job.head_sha.blank?

    Studio::Cable.safe_broadcast do
      reader = Ci::ProgressReader.new

      reader.eligible_tasks_for(job.repo, job.head_branch).each do |task|
        pr_url = task.devops_url("pr").presence
        # The SAME locals the card render passes — a morph that dropped `label` would
        # silently rewrite the meter's "PR: 610" back to a bare "CI" on the first tick.
        broadcast_ci_slot("ci-progress-#{task.slug}", reader.for_task(task),
                          compact: true, test_id: "task-ci-progress",
                          label: ApplicationController.helpers.ci_meter_label(pr_url),
                          href: pr_url,
                          wrapper_class: "mb-1.5", inner_test_id: "task-card-ci-progress")
      end

      # A CI push for a release MEMBER's candidate-CI track refreshes the whole Next
      # Release card, so that lane's Assembling meter (the per-repo lanes tracker,
      # Ci::ProgressReader#for_release) updates live. release_ci_slot_for owns the
      # member + branch match, so this fires ONLY for a member's release-CI push — the
      # per-repo "<repo> G3 tests" slots it used to morph are now those Assembling meters.
      if (release = Release.current) &&
         reader.release_ci_slot_for(release, job.repo, job.head_branch)
        # :current ONLY. A CI tick cannot change Release.last_shipped, so pushing the
        # Last Release card here was a byte-identical redraw the client then had to
        # explain — and it explained it with confetti, once per upsert. Declared
        # `ci.progress` as well, so the silence holds if a future caller wires the
        # slot back up.
        release_modules(fx: "ci.progress", slots: [:current])
      end

      # The ladder row carries this repo's own CI meter, so a check upsert for ANY
      # ladder branch moves it — including the branches no task and no release member
      # is watching, which is precisely the case the two pushes above cannot cover.
      app_ladder if Ci::AppLadder::RUNGS.include?(job.head_branch.to_s)
    end
  end

  # One MORPH replace of a CI bar slot. Morph (not a plain replace) keeps the fill
  # element in place so its transition-[width] animates the new width instead of
  # snapping, and touches nothing else on the card. The rendered partial roots the
  # SAME #dom_id so the slot survives the next push.
  def self.broadcast_ci_slot(dom_id, progress, **bar_locals)
    rendered = ApplicationController.render(
      partial: CI_SLOT_PARTIAL, formats: [:html],
      locals: { dom_id: dom_id, progress: progress, **bar_locals }
    )
    Turbo::StreamsChannel.broadcast_stream_to(
      STREAM,
      content: ApplicationController.helpers.turbo_stream_action_tag(
        :replace, target: dom_id, method: "morph", template: rendered
      )
    )
  end

  # A gate run opened or closed (GateRun) — refresh the gate-bearing surfaces.
  # Release-grain runs re-render the release modules; task-grain runs replace the
  # task's board card in place (parity with checkpoint events — no stage move
  # implied). The ONE broadcast that also fires on UPDATE (GateRun.close! updates
  # the open row, unlike the append-only spines). Guarded like every other entry.
  def self.gate_run(run)
    if run.subject_type == "release"
      release_modules(fx: "gate_run.#{run.key}")
    else
      Studio::Cable.safe_broadcast do
        task = Task.find_by(slug: run.subject_slug)
        new(nil, task: task).deliver_replace if task
      end
    end
  end

  # An operator-approval flip (devops.approval_status → "waiting" / cleared) changed
  # no stage column and wrote no TaskEvent, so neither spine fired — refresh the card
  # in place so the WAITING APPROVAL bar appears (or drops) live, no reload. Same
  # event-less REPLACE as .gate_run; a no-op if the card isn't on the board. Called
  # from Task's after_update_commit and guarded so a cable failure never breaks the
  # approval write (SEV-1 guard).
  def self.approval_change(task)
    Studio::Cable.safe_broadcast { new(nil, task: task).deliver_replace }
  end

  # `task:` covers event-less broadcasts (gate runs, approval flips): the card render
  # only needs the task, so those callers pass it directly and use #deliver_replace.
  def initialize(event, task: nil)
    @event = event
    @task = task || event&.task
  end

  def deliver
    return nil if @task.nil?

    broadcast
  end

  # In-place card refresh with no event to dispatch on (see .gate_run).
  def deliver_replace
    return nil if @task.nil?

    replace_card
  end

  private

  # One websocket payload, picked from the event kind + the from/to columns.
  def broadcast
    if left_board?
      remove_card           # → archived: drop it from the active board
    elsif new_card?
      prepend_card          # genesis: a brand-new card at the top of Designed
    elsif @event.intent? || @event.checkpoint?
      replace_card          # in place: intent ticker / lifecycle checkpoint
    else
      move_card             # stage move: remove the old card, prepend a fresh one
    end
  end

  def replace_card
    Turbo::StreamsChannel.broadcast_replace_to(STREAM, target: card_id, partial: PARTIAL, locals: card_locals)
  end

  def prepend_card
    Turbo::StreamsChannel.broadcast_prepend_to(STREAM, target: dropzone_id, partial: PARTIAL, locals: card_locals)
  end

  def remove_card
    Turbo::StreamsChannel.broadcast_stream_to(
      STREAM,
      content: turbo_stream_action_tag(:remove, target: card_id, data: { exit_action: "archive" })
    )
  end

  def move_card
    Turbo::StreamsChannel.broadcast_stream_to(STREAM, content: move_stream_content)
  end

  def move_stream_content
    [
      turbo_stream_action_tag(:remove, target: card_id),
      turbo_stream_action_tag(:prepend, target: dropzone_id, template: rendered_card)
    ].join
  end

  def rendered_card
    ApplicationController.render(partial: PARTIAL, formats: [:html], locals: card_locals)
  end

  def card_id
    "card-#{@task.slug}"
  end

  def dropzone_id
    "dropzone-#{zone(@task.stage)}"
  end

  # The on-board column a stage lives in. Blocked tasks are `building` tasks now
  # (a block is a building attribute), so no stage remap is needed.
  def zone(stage)
    stage
  end

  def left_board?
    !BOARD_ZONES.include?(zone(@task.stage))
  end

  def new_card?
    @event.transition? && @event.from_stage.nil?
  end

  # The same locals the board loop renders the card with — the deploy-board variant.
  # The task's conversation activities are loaded ONCE (see #activities) and the
  # three activity-derived locals — latest, count, and the ever_blocked block-tone
  # flag — are all read from that in-memory set. Passing +ever_blocked+ preloaded
  # (the board loop's @ever_blocked_slugs equivalent) keeps Task#block_state from
  # self-querying ever_blocked? on this single-card render.
  def card_locals
    {
      task: @task,
      agents: Agent.order(:position).to_a,
      crew_board: :deploy,
      mascot: Pokemon.find_by(slug: @task.devops_field("mascot").to_s.presence),
      type_enumerals: type_enumerals,
      latest_activity: activities.max_by(&:created_at),
      activity_count: activities.size,
      ever_blocked: activities.any?(&:blocking_feedback?),
      unresolved_feedback: @task.unresolved_feedback_activity,
      review_in_progress: @task.review_in_progress?
    }
  end

  # The task's conversation activities (comment/clarification/qa_feedback/handoff),
  # loaded once into memory so #card_locals derives latest/count/ever_blocked from
  # the same set instead of firing a separate query for each.
  def activities
    @activities ||= Activity.for_task(@task)
                            .where(activity_type: Activity::TASK_CONVERSATION_TYPES)
                            .to_a
  end

  def type_enumerals
    @type_enumerals ||= Pokemon.type_enumerals
  end
end

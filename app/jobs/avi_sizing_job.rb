# Avi auto shirt-sizes a task the moment it lands in `designed` WITHOUT a po_size,
# in PARALLEL with the Pokémon starting the build (the trigger enqueues this and
# does NOT block the create/move — see Task#enqueue_avi_sizing_if_designed_unsized).
#
# What it does:
#   1. Loads the task; bails if it's gone or already sized (idempotent — a re-run,
#      or a manual size set between enqueue and run, is a clean no-op and NEVER
#      clobbers the existing size).
#   2. Asks Avi (the LLM adapter, Avi::Sizer) for a t-shirt size. A nil answer
#      (no api key / unparseable) leaves po_size blank — we never fabricate a size.
#   3. Sets po_size (re-checking blank right before the write so two racing jobs
#      can't stomp each other).
#   4. Attributes the sizing to Avi so it surfaces in the heartbeat Agent column.
#
# Backend discipline — best-effort, never crash: the whole body is rescued into
# ErrorLog. We deliberately DON'T re-raise (so ApplicationJob's retry_on doesn't
# storm the LLM) — a failed sizing degrades to "unsized", it never blocks the task.
class AviSizingJob < ApplicationJob
  AGENT = "avi".freeze
  # A self-contained, already-closed narration activity — Avi's sizing is one discrete
  # act, not an open-ended activity, so we never touch the creating session's
  # single-open-activity invariant (opening a real activity would auto-close whatever the
  # builder is narrating live).
  ACTIVITY_CATEGORY = "Plan".freeze

  def perform(task_slug)
    task = Task.find_by(slug: task_slug)
    return if task.nil?
    return if task.po_size.present? # idempotent: never clobber an existing size

    size = Avi::Sizer.new(task).call
    return if size.blank? # LLM unavailable/unparseable — leave it unsized, don't fabricate

    # Re-check blank right before the write: a manual size (or a racing job) may
    # have landed while the LLM call was in flight. First writer wins.
    return if task.reload.po_size.present?

    task.update!(po_size: size)
    attribute_to_avi(task, size)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = task if task
    log.target_name = task&.slug || task_slug
    log.save!
  end

  private

  # Record the sizing as an agent=avi event so the heartbeat Agent column shows
  # Avi did this. Preferred path: stamp a closed AgentActivity on the CREATING
  # session (captured by bin/task on create into devops.session_id) so it shows in
  # that session's heartbeat, attributed to Avi. No session (CI/manual create) ->
  # fall back to a task-scoped Activity so the attribution is never lost.
  #
  # Rescued separately: the po_size write is the primary, durable outcome — an
  # attribution hiccup must not undo it (or re-raise into the job's ErrorLog and
  # look like the sizing failed).
  def attribute_to_avi(task, size)
    session_id = task.devops_session_id
    if session_id.present?
      now = Time.current
      AgentActivity.create!(
        session_id: session_id,
        category: ACTIVITY_CATEGORY,
        reason_slug: "Avi shirt-sizes #{task.slug}",
        outcome_slug: "sized #{size}",
        task_slug: task.slug,
        agent: AGENT,
        mascot: task.devops["mascot"].presence,
        stage: task.stage,
        seq: AgentActivity.next_seq_for(session_id),
        opened_at: now,
        closed_at: now
      )
    else
      Activity.create!(
        task_slug: task.slug,
        agent_slug: AGENT,
        activity_type: "comment",
        description: "Avi shirt-sized this task #{size}."
      )
    end
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = task
    log.target_name = task.slug
    log.save!
  end
end

# Request- and job-scoped context. This file OVERRIDES studio-engine's Current
# (the engine is non-isolated, so the host's app/models/current.rb wins and a
# fresh `attribute` list REPLACES the gem's wholesale). It must therefore carry
# the engine baseline forward: `:user`, populated by the engine's
# set_current_context before_action (Studio::ErrorHandling) on every
# authenticated request and read by audit/logging layers. Dropping it silently
# breaks Current.user app-wide.
#
# The task_event_* attributes hold context for the NEXT task stage transition:
# populated by the request layer (Api::V1::TasksController, TasksController, via
# bin/task) and drained by Task#record_stage_event into the TaskEvent it writes.
# Rails resets CurrentAttributes per request/job, so these are unset everywhere
# else — which means model-driven and conductor transitions record only the
# deterministic spine (from/to/duration), with no usage attribution.
class Current < ActiveSupport::CurrentAttributes
  # Engine baseline (studio-engine Current) — carried forward so the engine's
  # set_current_context can populate it on authenticated requests.
  attribute :user
  attribute :task_event_source, :task_event_actor, :task_event_model
  attribute :task_event_tokens_in, :task_event_tokens_out, :task_event_cost
  # Optional override for the two reviewers recorded on a submitted→reviewed
  # event (the avatars payload). When unset, Task#stage_event_metadata selects
  # the pair via ReviewerSelector — so the avatars populate no matter who drove
  # the transition; set it when Avi curated the pair explicitly.
  attribute :task_event_reviewers
  # Set ONLY by Release::Conductor.adopt!(override: true) when an operator merges
  # a NOT-yet-`reviewed` PR past the review gate (`bin/release merge --override`).
  # Drained by Task#write_stage_event onto the very transition event the bypassed
  # flip writes (metadata["review_bypassed"] = true), so the review skip lands on
  # the same audit spine `bin/task move` writes — the override's paper trail.
  attribute :task_event_review_bypass
  # The Claude/Codex SESSION id of the conductor running `bin/release`, injected
  # into every conductor record op's `heroku run rails runner` payload (see
  # bin/release#conductor_payload) — local shell env doesn't cross the heroku-run
  # boundary, so the CLI passes it in-band. Release::Conductor (adopt!/curate!/
  # ship!) drains it onto the release via Release#stamp_conductor_mascot!, so the
  # deployment wears the SESSION's Pokémon mascot — the agent working it.
  attribute :conductor_session_id

  # Set the per-transition usage attributes from a captured-usage hash for the
  # duration of the block, then clear them — so a conductor/release flip that
  # runs OUTSIDE the request layer (Release::Conductor.adopt!, Release#ship!,
  # driven by bin/release capturing the delta from its local transcript) can
  # stamp model/tokens/cost onto the TaskEvent it's about to write, exactly like
  # a `bin/task move` does via the controller. Clearing after each task is what
  # keeps a BATCHED flip (N tasks in one runner process) from mis-attributing
  # task B's event with task A's usage. A nil/blank usage is a no-op (the flip
  # records the deterministic spine only — never fabricated). Tolerates string OR
  # symbol keys so both the bin/release snippet and in-process callers work.
  def self.with_task_event_usage(usage)
    usage = usage.presence
    return yield unless usage

    self.task_event_model      = (usage[:model] || usage["model"]).presence
    self.task_event_tokens_in  = (usage[:tokens_in] || usage["tokens_in"]).presence&.to_i
    self.task_event_tokens_out = (usage[:tokens_out] || usage["tokens_out"]).presence&.to_i
    self.task_event_cost       = (usage[:cost] || usage["cost"]).presence&.to_d
    yield
  ensure
    if usage
      self.task_event_model = nil
      self.task_event_tokens_in = nil
      self.task_event_tokens_out = nil
      self.task_event_cost = nil
    end
  end
end

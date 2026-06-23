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
end

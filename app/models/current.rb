# Request-scoped context for the NEXT task stage transition. Populated by the
# request layer (Api::V1::TasksController, TasksController, via bin/task) and
# drained by Task#record_stage_event into the TaskEvent it writes. Rails resets
# CurrentAttributes per request/job, so these are unset everywhere else — which
# means model-driven and conductor transitions record only the deterministic
# spine (from/to/duration), with no usage attribution.
class Current < ActiveSupport::CurrentAttributes
  attribute :task_event_source, :task_event_actor, :task_event_model
  attribute :task_event_tokens_in, :task_event_tokens_out, :task_event_cost
end

class TaskTransition < TaskEvent
  self.table_name = "task_events"

  default_scope { where(kind: TaskEvent::TRANSITION) }
end

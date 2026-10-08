# frozen_string_literal: true

# What to do about an approval request that cannot be honoured, in one place.
# Task's 422 (Task.guard_approval_request_stage!) and bin/task's drop warning
# (#warn_dropped_approval_request!) both print this sentence, so they cannot
# disagree. bin/task (no Rails) requires this file; Task reads it through autoload.
#
# The remedy is a write the reader can make where the task stands, never a move
# back: from `reviewed` on, the code is already on accepted.
module ApprovalRequestRemedy
  module_function

  def sentence(command: "bin/task", slug: "<task-slug>")
    "Record the operator's answer where you stand: #{command} update #{slug} --approval approved, " \
      "or #{command} update #{slug} --approval changes_requested; both are legal at every stage. " \
      "If you still need his eyes on merged work, point him at the QA candidate once the " \
      "qa-release sweep deploys it. Do not move the task back to re-open the request: a backward " \
      "move un-merges nothing, because from reviewed on the code is already on accepted."
  end
end

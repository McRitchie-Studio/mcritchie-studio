# frozen_string_literal: true

# Renders one TaskCardComponent in a view test. `given` names the inputs the
# test is about; every other input is read from the task, and the card shows no
# mascot, note or soul unless the test hands one in.
module TaskCardRendering
  def task_card_preloads(task, agents: @agents, **given)
    TaskCardComponent::Preloads.new(**{
      agents: agents, mascot: nil, type_enumerals: nil, latest_activity: nil, activity_count: 0,
      unresolved_feedback: task.unresolved_feedback_activity, ever_blocked: task.ever_blocked?,
      review_in_progress: task.review_in_progress?, ci_progress: Ci::ProgressReader.new.for_task(task),
      resubmission: task.resubmission, agent_session: nil
    }.merge(given))
  end

  def render_task_card(task, crew_board: :deploy, agents: @agents, **given)
    render TaskCardComponent.new(task: task, preloads: task_card_preloads(task, agents: agents, **given),
                                 crew_board: crew_board)
  end
end

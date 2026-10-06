# /epics — the epic view (devops-v3-design.md sections 3 and 10, piece 7). An epic
# is the handle its tasks carry (tasks.epic_slug); there is no Epic table, so both
# pages read Task through EpicSummary. Admin-only, like the boards they link from.
class EpicsController < ApplicationController
  include TaskCardPreloads

  # The tasks one epic page draws. An epic is dozens of tasks, not thousands, but
  # the page preloads each task's events, so the read is bounded the
  # way the board's archive column is (HOTFIX archived-board-crashes-prod) — the
  # newest SHOW_LIMIT, with the true total in the header.
  SHOW_LIMIT = 200

  def index
    @epics = EpicSummary.all
  end

  def show
    @epic = EpicSummary.find(params[:slug])
    raise ActiveRecord::RecordNotFound, "no task carries epic #{params[:slug].inspect}" unless @epic

    tasks = Task.for_epic(@epic.slug).includes(:task_events, :gate_runs)
                .order(updated_at: :desc).limit(SHOW_LIMIT).to_a
    load_board_task_conversation(tasks)
    load_task_card_readers(tasks)
    @agents = Agent.order(:position)
    @tasks_by_stage = tasks.group_by(&:stage)
    @drawn_count = tasks.size
  end
end

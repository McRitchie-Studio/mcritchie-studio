module Admin
  # Forgetting a note about an agent person (docs/agents/system/agent-message-loop.md,
  # "Memory"): the delete button on /admin/agent_messages/:id's notes panel.
  # Admin only; a form post, so Rails' CSRF check guards it. The console twin is
  # `bin/rails agent_people:forget NOTE=<id>`.
  class AgentPersonNotesController < ApplicationController
    before_action :require_admin

    def destroy
      note = AgentPersonNote.find(params[:id])
      note.destroy!
      back = AgentMessage.find_by(id: params[:message_id])
      redirect_to back ? admin_agent_message_path(back) : admin_agent_messages_path,
                  notice: "Forgot the note: #{note.body.truncate(80)}"
    end
  end
end

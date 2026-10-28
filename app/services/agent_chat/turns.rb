module AgentChat
  # A thread's rows as the contract's turns (epic .agents/epics/agent-chat-primitive.md):
  # `{id, role, text, created_at, status}`. One row is one message, so it gives
  # a USER turn (what the visitor typed) and, once answered, an AGENT turn. Both
  # carry the row's id: `after` is a message id, and a turn is keyed by (id, role).
  #
  # status, on both turns of a row:
  #   pending    stored, waiting for the dispatcher (received)
  #   typing     the dispatcher holds it (claimed): the answer is being written
  #   answered   the answer is in (completed, with words)
  #   failed     no answer is coming: held, dead, unrouted, or completed empty
  module Turns
    LIMIT = 50

    module_function

    def for(rows) = rows.flat_map { |row| for_row(row) }

    def for_row(row)
      status = status_for(row)
      turns = [ { id: row.id, role: "user", text: row.content.to_s, created_at: row.created_at.iso8601(3), status: status } ]
      if status == "answered"
        at = row.reply_posted_at || row.completed_at || row.updated_at
        turns << { id: row.id, role: "agent", text: row.response_text.to_s, created_at: at.iso8601(3), status: status }
      end
      turns
    end

    def status_for(row)
      case row.status
      when "received" then "pending"
      when "claimed" then "typing"
      when "completed" then row.response_text.present? ? "answered" : "failed"
      else "failed"
      end
    end

    # Whether an answer is still coming anywhere on the thread.
    def pending?(thread_key)
      thread_key.present? &&
        AgentMessage.where(channel: "web", thread_key: thread_key, status: AgentMessage::OPEN_STATUSES).exists?
    end
  end
end

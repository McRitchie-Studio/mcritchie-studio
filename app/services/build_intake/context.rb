module BuildIntake
  # The INTAKE part of the context bundle for a message on a /build thread
  # (AgentMessages::MemoryBundle#bundle, "intake"), which the worker's
  # ContextBuilder#intake_block turns into Xan's instructions for this turn.
  #
  # Code-shaped on purpose: the step names, whether each is set, and the values
  # a TAP set, each already held to its card's rules (a CTO name, a palette
  # name, a subdomain, portrait keys). The one free text, the confirmed idea
  # (title, features, sentence), is sent under "idea" for the worker to fence. Nothing here is a message.
  module Context
    module_function

    def for(message)
      request = BuildIntake.request_for(message)
      return nil unless request

      checklist = request.intake_checklist
      {
        "steps" => BuildIntake::STEPS,
        "done" => checklist,
        "next" => request.next_intake_step,
        "signed_in" => request.user_id.present?,
        "values" => {
          "cto_name" => request.cto_name,
          "portrait" => request.cto_avatar,
          "palette" => request.palette.presence&.dig("name"),
          "address" => request.subdomain
        }.compact,
        "idea" => request.answers.is_a?(Hash) ? idea(request.answers) : {},
        "follow_ups" => follow_ups(message),
        "portraits" => Portraits::KEYS,
        "cards" => Card::KINDS
      }
    end

    # The confirmed idea as the worker's prompt fences it: strings only, the
    # features joined into one line.
    def idea(answers)
      out = answers.slice("title", "idea", "audience", "day_one").select { |_, v| v.is_a?(String) }
      out["features"] = Array(answers["features"]).grep(String).join("; ") if answers["features"].present?
      out
    end

    # How many of Xan's earlier answers on this thread came BEFORE the idea was
    # confirmed: the idea gets at most two follow-up questions.
    def follow_ups(message)
      AgentMessage.where(channel: "web", thread_key: message.thread_key, status: "completed")
                  .where("agent_messages.id < ?", message.id)
                  .where("agent_messages.action_summary IS DISTINCT FROM ?", Caps::CAP_SUMMARY)
                  .count
    end
  end
end

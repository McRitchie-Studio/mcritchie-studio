module AgentMessages
  # Mail an agent must never answer, decided before anything is stored
  # (docs/agents/system/agent-message-loop.md, "Email", loop safety). Pure:
  # headers in, a reason (or nil) out.
  #
  #   our own outbound   it carries X-McRitchie-Agent (stamped on every reply we send)
  #   a CTO to a CTO     From is one of the fleet's own addresses (EmailRoutes#agent_address?):
  #                      a soul alias, team@, or another soul's address
  #   auto replies       Auto-Submitted other than `no` (RFC 3834), X-Autoreply,
  #                      X-Autorespond, Precedence bulk|list|junk|auto_reply, List-Id
  #   bounces            a null Return-Path (<>), a delivery report (multipart/report),
  #                      or a mailer-daemon / postmaster / no-reply sender
  #
  # A header that only ever SUPPRESSES an answer is safe to read from the
  # sender: forging one can only make us stay quiet.
  #
  # OUR OWN GROUPS ARE NOT MAILING LISTS. The soul aliases are Google groups that
  # redirect into team@; when a group stamps its own List-Id (an id under
  # mcritchie.studio), that List-Id and the Precedence: list beside it are not
  # read as an outside list. Every other List-Id is.
  class EmailLoopGuard
    AGENT_HEADER = "X-McRitchie-Agent".freeze
    DAEMON = /\A(?:mailer-daemon|postmaster|no-?reply|do-?not-?reply|bounces?)(?:[+.-].*)?\z/i
    PRECEDENCE = /\A(?:bulk|list|junk|auto_reply)\z/i
    OWN_LIST = /(?:\A|[.<])mcritchie\.studio>?\z/i

    def initialize(routes:)
      @routes = routes
    end

    # Why `headers` ([name, value] pairs, EmailTrust.headers) must not be
    # answered, or nil. `from` is the parsed From address.
    def reason(headers, from:)
      value = ->(name) { headers.find { |n, _| n.casecmp?(name) }&.last.to_s.strip }
      present = ->(name) { headers.any? { |n, _| n.casecmp?(name) } }

      return "our own outbound (#{AGENT_HEADER})" if present.call(AGENT_HEADER)
      return "no From address" if from.blank?
      return "from a fleet address (#{from}): never a CTO to a CTO" if @routes.agent_address?(from)
      return "from a mailer daemon (#{from})" if from.split("@", 2).first.to_s.match?(DAEMON)
      return "a bounce (null Return-Path)" if value.call("Return-Path").match?(/\A<\s*>\z/)
      return "a delivery report" if value.call("Content-Type").match?(%r{\Amultipart/report}i)

      auto = value.call("Auto-Submitted")
      return "auto-submitted (#{auto})" if auto.present? && !auto.casecmp?("no")
      return "an auto reply (X-Autoreply)" if present.call("X-Autoreply") || present.call("X-Autorespond")

      list_id = value.call("List-Id")
      own_list = list_id.present? && list_id.match?(OWN_LIST)
      return "a mailing list (List-Id #{list_id[0, 80]})" if list_id.present? && !own_list

      precedence = value.call("Precedence")
      if precedence.match?(PRECEDENCE) && !(own_list && precedence.casecmp?("list"))
        return "bulk mail (Precedence: #{precedence})"
      end

      nil
    end
  end
end

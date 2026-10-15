# frozen_string_literal: true

require "json"

module AgentMailbox
  # The notes section a mailbox answer may end with (docs/agents/system/agent-message-loop.md,
  # "Memory"): durable facts about the sender, which the board files under that
  # person (AgentPersonNote). The model writes them after its reply as
  #
  #   <the reply>
  #   ===NOTES===
  #   ["Favorite color is purple."]
  #
  # WHY A DELIMITER. `claude -p --output-format json` puts the model's whole text
  # in the envelope's `result`; there is no second field the model can fill. A
  # line the code splits on keeps the reply path exactly as it is (an answer
  # with no notes is unchanged), and the split is a pure function the tests pin.
  # A ```json fence around the array is accepted too, since models add one.
  #
  # The section is ALWAYS cut from the posted reply, even when its JSON is
  # broken, so facts never reach the channel; the board cuts at the same line
  # again (AgentMessage.without_notes). This side only parses: the board decides
  # what is kept (length, plain text, dedupe, caps).
  module NoteBlock
    DELIMITER = "===NOTES==="
    MAX = 3
    LINE = /^[ \t]*#{Regexp.escape(DELIMITER)}[ \t]*$/

    # [reply, facts]: the reply without its notes section (stripped), and up to
    # MAX strings from the section (none when it is absent or not a JSON array
    # of strings).
    def self.split(text)
      text = text.to_s
      cut = text.index(LINE)
      return [ text.strip, [] ] unless cut

      reply = text[0, cut].strip
      section = text[cut..].sub(LINE, "").strip
      json = section[/\A```(?:json)?\s*(.*?)\s*```/m, 1] || section
      [ reply, facts_from(json) ]
    end

    def self.facts_from(json)
      data = JSON.parse(json)
      data = data["facts"] if data.is_a?(Hash)
      return [] unless data.is_a?(Array)

      data.select { |f| f.is_a?(String) }.map(&:strip).reject(&:empty?).first(MAX)
    rescue JSON::ParserError
      []
    end
    private_class_method :facts_from
  end
end

# frozen_string_literal: true

require "json"
require_relative "agent_note_block"

module AgentMailbox
  # The proposal section a domain agent's answer may end with
  # (docs/agents/system/agent-message-loop.md, "Proposals and confirm"): what the
  # agent offers to do, for the owner to confirm. The model writes it as
  #
  #   <the reply>
  #   ===PROPOSAL===
  #   {"capability": "board_status", "kind": "ask", "params": {}, "summary": "Count the board by stage"}
  #
  # THE SAME PATTERN AS NOTES (NoteBlock): one delimiter, matched loosely
  # (bold, spaced, lowercased, mid-sentence, two or more "="), the reply cut at
  # the first match, and a headed tail ("Proposal:" then a JSON object) cut even
  # with no delimiter. A false match only shortens a reply; a missed one would
  # post the block. The worker and the board cut with this one module, against
  # one set of fixtures (test/support/proposal_block_fixtures.rb).
  #
  # NOTES AND PROPOSAL TOGETHER. Either may come first. The proposal section runs
  # from its marker to the notes marker (when notes follow) or to the end; it is
  # lifted out first, and NoteBlock then splits what is left.
  #
  # THIS SIDE ONLY PARSES. Whether a proposal names a real capability, fits its
  # schema and may be requested by this sender is the board's call
  # (AgentMailbox::DomainRegistry#validate, AgentProposal.record_from!).
  module ProposalBlock
    DELIMITER = "===PROPOSAL==="
    DELIMITER_PATTERN = /(?:^|(?<=[.!?:]))[*_`~#> \t]*={2,}[ \t*_]*proposal\b[ \t*_:]*=*[*_`~ \t]*/i
    HEADED_TAIL = /^[*_`~#> \t]*proposal[ \t*_:=-]*\n+[ \t]*(?:```(?:json)?[ \t]*\n)?[ \t]*\{.*\}[ \t]*(?:\n[ \t]*```)?\s*\z/im

    # [text without the proposal section, the parsed Hash or nil]. The Hash is
    # nil when there is no section or its JSON is not an object; the section is
    # removed either way.
    def self.extract(text)
      text = text.to_s
      if (match = DELIMITER_PATTERN.match(text))
        start = match.begin(0)
        after = match.end(0)
        notes = NoteBlock::DELIMITER_PATTERN.match(text, after)
        finish = notes ? notes.begin(0) : text.length
        section = text[after...finish]
        rest = undangled(text[0...start].rstrip)
        rest = "#{rest}\n#{text[finish..]}" if notes
        [ rest, parse(section) ]
      elsif (match = HEADED_TAIL.match(text))
        [ undangled(text[0...match.begin(0)].rstrip), parse(match[0].sub(/\A[^\n]*\n/, "")) ]
      else
        [ text, nil ]
      end
    end

    # [reply, notes, proposal]: the whole answer split three ways, as the worker
    # sends it and the board cuts it again.
    def self.split(text)
      rest, proposal = extract(text)
      reply, notes = NoteBlock.split(rest)
      [ reply, notes, proposal ]
    end

    def self.reply(text) = split(text).first

    def self.parse(section)
      body = section.to_s.strip
      body = body[/\A```(?:json)?\s*(.*?)\s*```/m, 1] || body.sub(/\s*```\s*\z/, "")
      body = body[/\{.*\}/m].to_s
      data = JSON.parse(body)
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end
    # A cut inside a ``` fence leaves its opener at the end of the reply.
    def self.undangled(text)
      return text if text.scan("```").size.even?

      text.sub(/\s*```[a-z]*\s*\z/i, "").rstrip
    end

    private_class_method :parse, :undangled
  end
end

# frozen_string_literal: true

require "json"

module AgentMailbox
  # The notes section a mailbox answer may end with (docs/agents/system/agent-message-loop.md,
  # "Memory"): durable facts about the sender, which the board files under that
  # person (AgentPersonNote). The model is asked to write them after its reply as
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
  # LOOSE ON PURPOSE. A model does not always write the line exactly: it puts it
  # mid-sentence ("Got it! ===NOTES=== [...]"), bolds it ("**===NOTES===**"),
  # spaces it ("=== NOTES ==="), or lowercases it. DELIMITER_PATTERN matches all
  # of those anywhere in the text, and the reply is cut at the FIRST match. A
  # false match only shortens a reply; a missed one would post the facts. When no
  # delimiter matches, HEADED_TAIL still cuts a reply that ENDS in a notes-like
  # heading line ("Notes:", "## NOTES") followed by a JSON array.
  #
  # THE ONE PATTERN. The board cuts with this same module (AgentMessage requires
  # this file), so the worker and the board can never disagree about where a
  # notes section starts. This side only parses: the board decides what is kept
  # (length, plain text, directives, dedupe, caps).
  #
  # WHAT IS GUARANTEED. Text from the first loose delimiter on, or a headed JSON
  # tail, is never posted, even when its JSON is broken. A fact the model writes
  # into the reply's prose WITHOUT any delimiter or heading is indistinguishable
  # from the reply and is posted as written.
  module NoteBlock
    DELIMITER = "===NOTES==="
    MAX = 3
    # Optional markdown (* _ ` ~ # >) and spaces, two or more "=", the word
    # NOTES in any case, then optional ":" "=" and markdown, starting a line or
    # right after a sentence's end (. ! ? :). Not after a word, so code such as
    # `count == notes.size` in an answer is never mistaken for the marker.
    DELIMITER_PATTERN = /(?:^|(?<=[.!?:]))[*_`~#> \t]*={2,}[ \t*_]*notes\b[ \t*_:]*=*[*_`~ \t]*/i
    # No delimiter, but the text ends in a line that is only a "notes" heading
    # (decorated or not) and then a JSON array, fenced or bare.
    HEADED_TAIL = /^[*_`~#> \t]*notes[ \t*_:=-]*\n+[ \t]*(?:```(?:json)?[ \t]*\n)?[ \t]*\[.*\][ \t]*(?:\n[ \t]*```)?\s*\z/im

    # [reply, facts]: the reply without its notes section (stripped), and up to
    # MAX strings from the section (none when it is absent or not a JSON array
    # of strings).
    def self.split(text)
      text = text.to_s
      cut, section = locate(text)
      return [ text.strip, [] ] unless cut

      reply = dangling_fence_removed(text[0, cut].strip)
      json = section[/\A```(?:json)?\s*(.*?)\s*```/m, 1] || section.sub(/\s*```\s*\z/, "")
      [ reply, facts_from(json) ]
    end

    # The reply alone, as the board stores and posts it.
    def self.reply(text) = split(text).first

    # [index the section starts at, the section's text after its marker], or nil.
    def self.locate(text)
      if (match = DELIMITER_PATTERN.match(text))
        [ match.begin(0), match.post_match.strip ]
      elsif (match = HEADED_TAIL.match(text))
        [ match.begin(0), match[0].sub(/\A[^\n]*\n/, "").strip ]
      end
    end
    private_class_method :locate

    # A cut made inside a ``` fence leaves its opener at the end of the reply.
    def self.dangling_fence_removed(reply)
      return reply if reply.scan("```").size.even?

      reply.sub(/\s*```[a-z]*\s*\z/i, "").strip
    end
    private_class_method :dangling_fence_removed

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

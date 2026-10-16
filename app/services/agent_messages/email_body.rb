module AgentMessages
  # The NEW text of an email reply: what the sender wrote this time, without the
  # quoted history, the "On … wrote:" line, a forwarded block, or a signature.
  # Pure. The routing rule reads its first line, the proposal confirm reads it
  # whole (a reply reading exactly `go` confirms), and it is what the agent answers.
  module EmailBody
    MAX = 20_000

    module_function

    def new_text(body)
      lines = body.to_s.gsub("\r\n", "\n").gsub("\r", "\n").lines.map(&:chomp)
      kept = []
      lines.each_with_index do |line, i|
        break if cut?(line, lines[i + 1])

        kept << line
      end
      kept.join("\n").strip[0, MAX]
    end

    def cut?(line, following)
      stripped = line.strip
      return true if stripped.start_with?(">")
      return true if line.match?(/\A-- ?\z/) # the signature delimiter
      return true if stripped.match?(/\ASent from my /i)
      return true if stripped.match?(/\A-{2,}\s*(?:Original|Forwarded) Message\s*-{2,}\z/i)
      return true if stripped.match?(/\A-{5,} ?Forwarded message ?-{5,}\z/i)
      return true if stripped.match?(/\A_{5,}\z/)
      if stripped.match?(/\AOn\s.+/i)
        return true if stripped.match?(/wrote:\z/i) || following.to_s.strip.match?(/wrote:\z/i)
      end
      return true if stripped.match?(/\AFrom:\s.+/i) && following.to_s.strip.match?(/\A(?:Sent|Date):\s/i)

      false
    end
  end
end

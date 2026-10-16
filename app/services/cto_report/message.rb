module CtoReport
  # Builds one CTO report's Discord message (content + embeds) from facts the
  # code computed, in the soul's template voice (CtoReport::Voice).
  #
  #   content  "**Turf Monster · CTO report · Thu, Oct 15, 2026**", the voiced
  #            paragraph (opener, the day's state, and the board for the hub),
  #            then the signature
  #   embeds   the app's health detail, built by DailyAppReport::Message for
  #            this one app (counts, then the top error groups), so the per-app
  #            report and the combined one show the same lines; none when the
  #            app could not be read (the content says why)
  #
  # Fitted to Discord's limits by construction (the content is clipped at
  # 2,000 UTF-16 units; one embed sits under the 6,000 budget), because
  # ReportDestinations refuses an over-limit report. Counts only: no names or
  # emails (an address in a reason is redacted).
  class Message
    CONTENT_LIMIT = ReportDestinations::CONTENT_LIMIT
    REASON_LIMIT = 120

    def initialize(entry:, ending:, health:, board: nil)
      @entry = entry
      @ending = ending.in_time_zone(DailyAppReport::ZONE)
      @health = health
      @board = board
      @voice = Voice.for(entry.soul)
    end

    def to_h = { content: content, embeds: embeds }

    def content
      paragraph = [ say(:open), say(state_line) ]
      lines = [ "**#{@entry.app.name} · CTO report · #{@ending.strftime('%a, %b %-d, %Y')}**", paragraph.join(" ") ]
      lines << say(:board) if @board
      lines << "— #{@voice.fetch(:signature)}"
      DailyAppReport::Message.clip(lines.join("\n"), CONTENT_LIMIT)
    end

    def embeds
      return [] unless @health.ok?

      DailyAppReport::Message.new(ending: @ending, results: [ @health ]).embeds
    end

    # The slot values, every one computed here from the facts.
    def slots
      slots = { app: @entry.app.name, until: @ending.strftime("%b %-d, %-l:%M %p %Z"),
                activity: activity_phrase, problems: problems_phrase, reason: reason }
      slots.merge!(board_slots) if @board
      slots
    end

    private

    def say(key) = format(@voice.fetch(key), **slots)

    def state_line
      case @health.category
      when :unreachable then :unreachable
      when :errors then :errors
      when :activity then :activity
      else :quiet
      end
    end

    # "3 signups and 1 contact message" (the sections with a count, errors aside).
    def activity_phrase
      parts = Array(@health.sections).filter_map do |s|
        next if s[:key] == "errors" || s[:failure].present? || s[:count].to_i <= 0

        noun = s[:title].to_s.downcase
        "#{s[:count]} #{s[:count].to_i == 1 ? noun.singularize : noun}"
      end
      parts.to_sentence.upcase_first
    end

    # "4 errors in 2 kinds; contact messages could not be read".
    def problems_phrase
      parts = []
      if (errors = @health.error_count).positive?
        kinds = [ @health.error_kinds.to_i, Array(@health.error_groups).size, 1 ].max
        parts << "#{errors} #{'error'.pluralize(errors)} in #{kinds} #{'kind'.pluralize(kinds)}"
      end
      failed = @health.failed_sections.map { |s| s[:title].to_s.downcase }
      parts << "#{failed.to_sentence} could not be read" if failed.any?
      parts.join("; ").upcase_first
    end

    def reason
      text = @health.reason.to_s.gsub(DailyAppReport::Message::EMAIL, "[email]").squish
      DailyAppReport::Message.clip(text.presence || "no reason given", REASON_LIMIT)
    end

    def board_slots
      blocked = @board.blocked.to_i.positive? ? " (#{@board.blocked} blocked)" : ""
      { building: "#{@board.building}#{blocked}", in_review: @board.in_review, deploying: @board.deploying,
        shipped: @board.shipped, release: release_phrase }
    end

    def release_phrase
      release = @board.release
      return "No release in flight." unless release

      tasks = release[:tasks].to_i
      "Release in flight: #{release[:stage].to_s.tr('_', ' ')}, #{tasks} #{'task'.pluralize(tasks)}."
    end
  end
end

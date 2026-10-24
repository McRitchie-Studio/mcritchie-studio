module DailyAppReport
  # Builds the one Discord message (content + embeds) from the apps' health,
  # FITTED TO DISCORD'S LIMITS BY CONSTRUCTION: ReportDestinations refuses an
  # over-limit report rather than splitting it, so this side trims per-app
  # detail until it fits (lengths in UTF-16 units, as Discord counts).
  #
  #   content  the headline: date, the window, "7 apps: 3 quiet, 1 with errors, …",
  #            "Backups: 5 fresh, 1 missing", the not-wired apps, and any app
  #            that did not get an embed
  #   embeds   one per fetched or unreachable app (at most 10), worst first:
  #            counts, the backup line, then the top error groups; green / amber / red
  class Message
    CONTENT_LIMIT = ReportDestinations::CONTENT_LIMIT
    EMBEDS_LIMIT = ReportDestinations::EMBEDS_LIMIT
    # Under Discord's 6,000 so a rounding slip can never refuse the morning.
    EMBED_TOTAL_BUDGET = ReportDestinations::EMBED_TOTAL_LIMIT - 200
    TITLE_LIMIT = 80
    TOP_GROUPS = 3
    GROUP_CLASS_LIMIT = 60
    GROUP_MESSAGE_LIMIT = 90

    GREEN = 0x22C55E
    AMBER = 0xF59E0B
    RED = 0xDC2626
    COLORS = { quiet: GREEN, activity: GREEN, errors: AMBER, unreachable: RED }.freeze
    ORDER = %i[unreachable errors activity quiet].freeze
    EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/

    def self.length(text) = ReleaseNotes::DiscordClient.discord_length(text)

    # Cut `text` to at most `limit` UTF-16 units, ending in "…" when cut.
    def self.clip(text, limit)
      text = text.to_s
      return text if length(text) <= limit
      return "" if limit <= 0

      out = +""
      used = 0
      text.each_char do |ch|
        size = length(ch)
        break if used + size > limit - 1

        out << ch
        used += size
      end
      out << "…"
    end

    # `backups` is slug => backup line (DbBackupSweep.report_lines) for every
    # backed-up app, embedded or not; the headline counts all of them.
    def initialize(ending:, results:, backups: {})
      @ending = ending.in_time_zone(DailyAppReport::ZONE)
      @results = results
      @backups = backups.to_h
    end

    def to_h = { content: content, embeds: embeds }

    def embedded = ranked.first(EMBEDS_LIMIT)
    def overflow = ranked.drop(EMBEDS_LIMIT)

    def content
      head = [ "**Daily app report · #{@ending.strftime('%a, %b %-d, %Y')}**", headline, "Window: #{window_label}" ]
      backups = DbBackupSweep.report_summary(@backups)
      head << backups if backups
      not_wired = @results.select(&:not_wired?)
      head << "Not wired (no token): #{not_wired.map(&:name).join(', ')}" if not_wired.any?
      lines = head.map { |line| self.class.clip(line, 400) }
      if overflow.any?
        lines << "Also:"
        overflow.each_with_index do |app, i|
          line = "- #{self.class.clip(app.name, TITLE_LIMIT)}: #{summary(app)}"
          tail = "…and #{overflow.size - i} more"
          if self.class.length((lines + [ line, tail ]).join("\n")) > CONTENT_LIMIT
            lines << tail
            break
          end
          lines << line
        end
      end
      self.class.clip(lines.join("\n"), CONTENT_LIMIT)
    end

    # "7 apps: 3 quiet, 1 with activity, 1 with errors, 1 unreachable, 1 not wired"
    def headline
      counts = @results.map(&:category).tally
      parts = { quiet: "quiet", activity: "with activity", errors: "with errors", unreachable: "unreachable",
                not_wired: "not wired" }.filter_map { |cat, label| "#{counts[cat]} #{label}" if counts[cat].to_i.positive? }
      "#{@results.size} #{@results.size == 1 ? 'app' : 'apps'}: #{parts.join(', ').presence || 'none'}"
    end

    def window_label
      from = @ending - 1.day
      "#{from.strftime('%b %-d, %-l:%M %p')} to #{@ending.strftime('%b %-d, %-l:%M %p %Z')}"
    end

    def embeds
      list = embedded
      return [] if list.empty?

      share = EMBED_TOTAL_BUDGET / list.size
      list.map { |app| embed(app, share) }
    end

    private

    # Fetched and unreachable apps, worst first, catalog order within a kind.
    def ranked
      @ranked ||= @results.reject(&:not_wired?).each_with_index
                          .sort_by { |app, i| [ ORDER.index(app.category) || ORDER.size, i ] }.map(&:first)
    end

    def embed(app, share)
      title = self.class.clip(app.name, TITLE_LIMIT)
      footer = app.engine_version.present? ? self.class.clip("studio-engine #{app.engine_version}", 40) : nil
      room = share - self.class.length(title) - self.class.length(footer)
      room = [ room, ReportDestinations::EMBED_FIELD_LIMITS[:description] ].min
      hash = { title: title, description: description(app, room), color: COLORS.fetch(app.category, AMBER) }
      hash[:footer] = { text: footer } if footer
      hash
    end

    # Whole lines while they fit `room`; a group that does not fit is counted.
    def description(app, room)
      backup = @backups[app.slug]
      if app.unreachable?
        return self.class.clip([ "Unreachable (#{app.reason})", backup ].compact.join("\n"), room)
      end

      lines = [ counts_line(app), backup ].compact
      groups = Array(app.error_groups)
      if groups.any?
        kinds = [ app.error_kinds.to_i, groups.size ].max
        lines << "#{kinds} #{kinds == 1 ? 'kind' : 'kinds'} of error:"
        shown = 0
        groups.first(TOP_GROUPS).each do |group|
          line = group_line(group)
          break if self.class.length((lines + [ line, more_line(kinds - shown) ]).join("\n")) > room

          lines << line
          shown += 1
        end
        lines << more_line(kinds - shown) if kinds > shown
      end
      self.class.clip(lines.join("\n"), room)
    end

    def counts_line(app)
      parts = Array(app.sections).map do |s|
        s[:failure].present? ? "#{s[:title]} unavailable" : "#{s[:title]} #{s[:count]}"
      end
      parts.join(" · ").presence || "No sections reported"
    end

    def group_line(group)
      klass = self.class.clip(sanitize(group[:error_class]).presence || "Error", GROUP_CLASS_LIMIT)
      message = self.class.clip(sanitize(group[:message]), GROUP_MESSAGE_LIMIT)
      "`#{klass}` ×#{group[:count]}#{": #{message}" if message.present?}"
    end

    def more_line(remaining) = "+#{remaining} more"

    # One line, no Markdown code breaks, no email addresses.
    def sanitize(text) = text.to_s.gsub(EMAIL, "[email]").tr("`", "'").gsub(/\s+/, " ").strip

    def summary(app)
      case app.category
      when :unreachable then "unreachable (#{app.reason})"
      when :quiet then "quiet"
      else counts_line(app)
      end
    end
  end
end

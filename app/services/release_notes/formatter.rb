module ReleaseNotes
  class Formatter
    PRODUCTION_TASK_BASE_URL = "https://mcritchie.studio/tasks".freeze
    APP_GROUPS = [
      { key: "mcritchie-studio", label: "McRitchie Studio", emoji: "🪎", aliases: ["mcritchie-studio"] },
      { key: "turf-monster", label: "Turf Monster", emoji: "🐊", aliases: ["turf-monster"] },
      { key: "studio-engine", label: "Studio Engine", emoji: "💎", aliases: ["studio-engine"] },
      { key: "vault", label: "Vault", emoji: "🏛️", aliases: ["turf-vault", "vault"] },
      { key: "solana-studio", label: "Solana Studio", emoji: "🧱", aliases: ["solana-studio"] },
      { key: "rolio", label: "Rolio", emoji: "📇", aliases: ["rolio"] }
    ].freeze

    # Discord caps a single message at 10 embeds, so a rich render fits one summary
    # embed + up to 9 task cards. A release with more shipped tasks than that falls
    # back to the plain-text `message` layout (see #discord_payload).
    DISCORD_MAX_EMBEDS = 10
    MAX_TASK_EMBEDS = DISCORD_MAX_EMBEDS - 1
    # Embed accent colors (Discord wants an integer, not a hex string).
    SUMMARY_COLOR = 0x57F287 # green — the deploy headline
    NEUTRAL_COLOR = 0x2B2D31 # Discord's card grey — a task with no mascot tint
    # description line 1 joins app-emojis · cost · blocker with this spacer.
    FIELD_SEPARATOR = "   ·   ".freeze
    # completed_at render for the "shipped …" line (e.g. "3:28 PM").
    SHIPPED_TIME_FORMAT = "%-l:%M %p".freeze

    def initialize(app:, environment:, release:, sha:, url:, tasks:, checks: nil, release_train: nil)
      @app = app.presence || "mcritchie-studio"
      @environment = environment.presence || "production"
      @release = release.to_s.strip
      @sha = sha.to_s.strip
      @url = url.to_s.strip
      @tasks = Array(tasks)
      @checks = checks
      @release_train = release_train.to_s.strip
    end

    def message
      lines = [headline]
      lines << @url if @url.present?
      lines << ""
      lines.concat(group_lines)
      lines << ""
      lines << checks_line if checks_text.present?
      lines.join("\n")
    end

    # The Discord message payload to deliver, ready to splat into
    # DiscordClient.deliver. Rich embeds when the release fits Discord's 10-embed
    # cap (summary + up to 9 task cards), otherwise the plain-text `message`
    # fallback so a big release still ships its notes.
    def discord_payload
      embeddable? ? { embeds: embeds } : { content: message }
    end

    # True when the release fits the embed render — a summary embed plus one card
    # per task, within Discord's 10-embed-per-message cap.
    def embeddable?
      @tasks.size <= MAX_TASK_EMBEDS
    end

    # The ordered embed array: the green summary headline FIRST (index 0), then one
    # rich card per shipped task. Only meaningful when #embeddable? — a caller picks
    # via #discord_payload.
    def embeds
      [summary_embed] + @tasks.map { |task| task_embed(task) }
    end

    private

    # The leading deploy-summary embed — the headline + production url in green.
    def summary_embed
      embed = { title: headline, color: SUMMARY_COLOR }
      embed[:url] = @url if @url.present?
      embed
    end

    # One rich card for a shipped task: clickable title, mascot type-tint color,
    # the mascot's HD avatar thumbnail, and the two-line app/cost/blocker + shipped
    # description.
    def task_embed(task)
      embed = {
        title: task.title,
        url: task_url(task),
        color: task_color(task),
        description: task_description(task)
      }
      thumbnail = task_thumbnail(task)
      embed[:thumbnail] = thumbnail if thumbnail
      embed
    end

    # Line 1: "{app_emojis}   ·   {cost}   ·   {blocker}". Line 2 (when shipped):
    # "shipped {time}". Joined with a newline.
    def task_description(task)
      lines = [[app_emojis(task), task_cost(task), task_blocker(task)].join(FIELD_SEPARATOR)]
      shipped = shipped_line(task)
      lines << shipped if shipped
      lines.join("\n")
    end

    # One emoji per repo (in repo order, no separator), mapped through APP_GROUPS;
    # a repo that maps to no group is skipped.
    def app_emojis(task)
      task.devops_repositories.filter_map { |repo| group_for_repo(repo)&.fetch(:emoji) }.join
    end

    # The task's total cost as "$%.2f", or an em-dash when zero/nil.
    def task_cost(task)
      cost = task.total_cost
      return "—" if cost.nil? || cost.zero?

      format("$%.2f", cost)
    end

    def task_blocker(task)
      task.blocked_at.present? ? "❌" : "✅"
    end

    # "shipped 3:28 PM" from completed_at, or nil when the task never shipped (the
    # line is then skipped entirely).
    def shipped_line(task)
      return nil if task.completed_at.blank?

      "shipped #{task.completed_at.strftime(SHIPPED_TIME_FORMAT)}"
    end

    # The embed accent: the mascot Pokémon's signature type color as a Discord
    # integer, or the neutral grey when there's no mascot (or its color isn't seeded).
    def task_color(task)
      hex = mascot_for(task)&.signature_color
      hex.present? ? hex_to_int(hex) : NEUTRAL_COLOR
    end

    # The mascot's HD avatar as the embed thumbnail, or nil to omit it (no mascot).
    def task_thumbnail(task)
      url = mascot_for(task)&.avatar_url
      url.present? ? { url: url } : nil
    end

    # The task's mascot Pokémon (from devops.mascot), memoized per slug so a repeated
    # mascot across cards costs one query. nil when the task carries no mascot, the
    # mascot is a persona (a soul name, not a Pokémon slug), or the row is missing.
    def mascot_for(task)
      slug = task.metadata.dig("devops", "mascot").presence
      return nil unless slug

      @mascots_by_slug ||= {}
      return @mascots_by_slug[slug] if @mascots_by_slug.key?(slug)

      @mascots_by_slug[slug] = Pokemon.find_by(slug: slug)
    end

    # "#6390F0" → 6525168, the integer Discord's embed `color` field wants.
    def hex_to_int(hex)
      hex.to_s.delete("#").to_i(16)
    end

    def group_for_repo(repo)
      normalized = repo.to_s.strip
      APP_GROUPS.find { |group| group[:aliases].include?(normalized) }
    end

    def headline
      parts = ["🚀", "#{@environment.titleize} deployed:", app_label]
      release_detail = [@release.presence, short_sha.presence].compact
      parts << "#{release_detail.first} (#{release_detail.second})" if release_detail.size == 2
      parts << release_detail.first if release_detail.size == 1
      parts.join(" ")
    end

    def app_label
      group = APP_GROUPS.find { |candidate| candidate[:aliases].include?(@app.to_s) }
      group ? group[:label] : @app.to_s.tr("-", " ").titleize
    end

    def short_sha
      @sha[0, 7]
    end

    def group_lines
      grouped_tasks = tasks_by_group
      APP_GROUPS.flat_map do |group|
        tasks = grouped_tasks.fetch(group[:key], [])
        lines = ["#{group[:emoji]} #{group[:label]}"]
        lines.concat(task_lines(tasks))
        lines << ""
      end.tap(&:pop)
    end

    def task_lines(tasks)
      return ["• No deployed tasks"] if tasks.empty?

      tasks.map { |task| "• [#{escape_link_label(task.title)}](#{task_url(task)})" }
    end

    def tasks_by_group
      APP_GROUPS.to_h { |group| [group[:key], []] }.tap do |grouped|
        @tasks.each do |task|
          keys = group_keys_for(task)
          keys = [default_group_key] if keys.empty?
          keys.each { |key| grouped[key] << task unless grouped[key].include?(task) }
        end
      end
    end

    def group_keys_for(task)
      task.devops_repositories.filter_map { |repo| group_key_for(repo) }.uniq
    end

    def group_key_for(repo)
      group_for_repo(repo)&.fetch(:key)
    end

    def default_group_key
      group_key_for(@app) || APP_GROUPS.first.fetch(:key)
    end

    def task_url(task)
      "#{PRODUCTION_TASK_BASE_URL}/#{task.slug}"
    end

    def escape_link_label(value)
      value.to_s.gsub("[", "\\[").gsub("]", "\\]")
    end

    def checks_line
      text = checks_text
      text = "#{text}." unless text.end_with?(".")
      "Checks: #{text}"
    end

    def checks_text
      Array(@checks).flat_map { |check| check.to_s.split(/\n/) }
                    .map(&:strip)
                    .reject(&:blank?)
                    .join(", ")
    end
  end
end

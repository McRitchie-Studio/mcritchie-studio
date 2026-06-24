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

    private

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
      normalized = repo.to_s.strip
      APP_GROUPS.find { |group| group[:aliases].include?(normalized) }&.fetch(:key)
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

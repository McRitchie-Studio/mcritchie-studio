class Release
  # Pure release-builder autonomy policy. It turns the reviewed task queue into a
  # deterministic decision so agents do not infer release autonomy from prose.
  module BuilderPolicy
    module_function

    CONFIG_PATH = Rails.root.join("config", "release_builder.yml")
    AUTO_QA_ACTION = "auto_qa"
    PROPOSE_ACTION = "propose"

    Decision = Struct.new(
      :action, :reason, :task_slugs, :repositories, :risk_tags, :operator_gated_ship,
      keyword_init: true
    ) do
      def auto_qa?
        action == AUTO_QA_ACTION
      end

      def propose?
        action == PROPOSE_ACTION
      end

      def operator_gated_ship?
        operator_gated_ship == true
      end

      def to_h
        {
          "action" => action,
          "reason" => reason,
          "task_slugs" => task_slugs,
          "repositories" => repositories,
          "risk_tags" => risk_tags,
          "operator_gated_ship" => operator_gated_ship?
        }
      end
    end

    def config
      @config ||= YAML.load_file(CONFIG_PATH) || {}
    end

    def reload!
      @config = nil
      config
    end

    def evaluate(tasks)
      tasks = Array(tasks).compact
      repos = tasks.flat_map { |task| task_repositories(task) }.uniq.sort
      risk_tags = tasks.flat_map { |task| task_risk_tags(task) }.uniq.sort
      blocked = risk_tags.map(&:downcase) & blocked_risk_tags
      reasons = rejection_reasons(tasks: tasks, repos: repos, blocked: blocked)
      action = reasons.empty? ? AUTO_QA_ACTION : PROPOSE_ACTION

      Decision.new(
        action: action,
        reason: reasons.empty? ? "single task, single repo, no blocked risk tags" : reasons.join("; "),
        task_slugs: tasks.map { |task| task_slug(task) }.compact,
        repositories: repos,
        risk_tags: risk_tags,
        operator_gated_ship: production_ship_operator_gated?
      )
    end

    def auto_qa?(tasks)
      evaluate(tasks).auto_qa?
    end

    def rejection_reasons(tasks:, repos:, blocked:)
      reasons = []
      reasons << "no reviewed tasks supplied" if tasks.empty?
      reasons << "task count #{tasks.size} exceeds #{auto_qa_max_tasks}" if tasks.size > auto_qa_max_tasks
      reasons << "repo count #{repos.size} exceeds #{auto_qa_max_repos}" if repos.size > auto_qa_max_repos
      reasons << "blocked risk tags: #{blocked.sort.join(', ')}" if blocked.any?
      reasons
    end

    def auto_qa_config
      config.fetch("auto_qa", {})
    end

    def auto_qa_max_tasks
      auto_qa_config.fetch("max_tasks", 1).to_i
    end

    def auto_qa_max_repos
      auto_qa_config.fetch("max_repos", 1).to_i
    end

    def blocked_risk_tags
      Array(auto_qa_config.fetch("blocked_risk_tags", [])).map { |tag| tag.to_s.downcase }.uniq.sort
    end

    def production_ship_operator_gated?
      config.fetch("production_ship", {}).fetch("operator_gated", true) == true
    end

    def task_slug(task)
      return task.slug if task.respond_to?(:slug)

      hash_value(task, "slug").presence
    end

    def task_repositories(task)
      return task.devops_repositories if task.respond_to?(:devops_repositories)

      normalize_list(devops_value(task, "repositories"))
    end

    def task_risk_tags(task)
      return task.devops_risk_tags if task.respond_to?(:devops_risk_tags)

      normalize_list(devops_value(task, "risk_tags"))
    end

    def devops_value(task, key)
      devops = hash_value(task, "devops")
      devops ||= hash_value(hash_value(task, "metadata"), "devops")
      hash_value(devops, key)
    end

    def hash_value(source, key)
      return nil unless source.respond_to?(:[])

      source[key.to_s] || source[key.to_sym]
    end

    def normalize_list(value)
      values =
        case value
        when Array
          value
        else
          value.to_s.split(/[,\n]/)
        end
      values.map { |item| item.to_s.strip }.reject(&:blank?).uniq
    end
  end
end

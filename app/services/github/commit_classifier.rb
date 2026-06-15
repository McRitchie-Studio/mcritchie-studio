module Github
  module CommitClassifier
    BOT_LOGIN_PATTERNS = [
      /\Adependabot(?:\[bot\])?\z/i,
      /\Arenovate(?:\[bot\])?\z/i,
      /\Agithub-actions(?:\[bot\])?\z/i,
      /\[bot\]\z/i,
      /(?:^|[-_])bot\z/i
    ].freeze

    BOT_MESSAGE_PATTERNS = [
      /\bdependabot\b/i,
      /\brenovate\b/i,
      /\bgithub-actions\b/i,
      /\[bot\]/i
    ].freeze

    module_function

    def merge?(payload)
      parents = Array(payload["parents"])
      return true if parents.size > 1

      message(payload).match?(/\AMerge\b/i)
    end

    def bot?(payload)
      logins(payload).any? { |login| BOT_LOGIN_PATTERNS.any? { |pattern| login.match?(pattern) } } ||
        BOT_MESSAGE_PATTERNS.any? { |pattern| message(payload).match?(pattern) }
    end

    def message(payload)
      payload.dig("commit", "message").to_s
    end

    def logins(payload)
      [
        payload.dig("author", "login"),
        payload.dig("committer", "login"),
        payload.dig("commit", "author", "name"),
        payload.dig("commit", "committer", "name")
      ].compact.map(&:to_s).map(&:strip).reject(&:blank?)
    end
  end
end

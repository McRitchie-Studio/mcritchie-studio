module AgentMessages
  # The CTO chat asks a nameless owner for their first name IN THE THREAD, where
  # the engine's first-name modal used to open over the launch panel (task
  # cto-chat-quality-pass, Alex 2026-10-19: "The first name is weird").
  #
  # THE ASK is code: the CTO's opening greeting (ClientCtoHandover#greeting)
  # ends with QUESTION when the owner has no first name, and that turn carries
  # run_meta "asks_first_name". No model writes it.
  #
  # THE CAPTURE is deterministic, and only for the FIRST message after the ask
  # (the thread's newest turn is the asking one) while users.first_name is
  # still blank:
  #
  #   a name       "Ada", "I'm Ada Lovelace", "call me jo"   saved, answered in code
  #   a skip       "skip", "no thanks", "not now"             answered in code; the
  #                                                          controller records the
  #                                                          engine's session skip
  #   anything else                                          the model answers it as
  #                                                          usual; the ask is over
  #
  # THE WRITE is the engine's onboarding write (Studio::OnboardingController
  # #first_name), the same columns by the same rules: Studio::NameParts splits
  # the answer, each half within Studio::FIRST_NAME_MAX_LENGTH and the whole
  # within Studio::FULL_NAME_MAX_LENGTH, update_columns (no callbacks, no
  # validations elsewhere on the row), and `name` backfilled when blank. No new
  # storage: the skip is the engine's own session key.
  module FirstNameAsk
    QUESTION = "Before we dive in, what should I call you? Just your first name is fine, or say skip.".freeze
    META = "asks_first_name".freeze
    SUMMARY = "first name".freeze
    NEXT_STEP = "What would you like to add or change first, or what can I tell you about the plan?".freeze

    SKIP = /\A(?:skip(?:\s+(?:it|this|for now))?|pass|no(?:pe)?|no,?\s+thanks?|nah|not now|later|maybe later|rather not|i'?d rather not|prefer not to say)\z/i
    INTRO = /\A(?:(?:hi|hey|hello)[\s,!.]+)?(?:i'?m|i am|it'?s|its|call me|my name is|my name'?s|name'?s|this is)\s+/i
    WORD = /\A\p{L}[\p{L}\p{M}'’.-]*\z/u
    MAX_WORDS = 3
    # One word that answers the question without being a name.
    NOT_NAMES = %w[yes yeah yep no ok okay sure hi hey hello thanks thank help what why how who where when hmm idk
                   test testing name first me you].to_set.freeze

    Answer = Struct.new(:kind, :name, keyword_init: true) do
      def skip? = kind == :skip
      def name? = kind == :name
    end

    module_function

    # Whether the greeting for `user` asks for a first name.
    def ask?(user) = user.respond_to?(:first_name) && user.first_name.blank?

    # Whether `user`'s next message in `thread_key` answers the ask: their name
    # is still blank and the thread's newest turn is the one that asked.
    def pending?(user, thread_key)
      return false unless ask?(user)

      newest = AgentMessage.where(channel: "web", thread_key: thread_key).order(id: :desc).pick(:run_meta)
      newest.is_a?(Hash) && newest[META] == true
    end

    # The Answer `text` gives the ask, or nil when it is neither a name nor a skip.
    def parse(text)
      value = text.to_s.strip.gsub(/\s+/, " ").sub(/[.!]+\z/, "").strip
      return nil if value.empty? || value.length > Studio::FULL_NAME_MAX_LENGTH + 20

      return Answer.new(kind: :skip) if value.match?(SKIP)

      value = value.sub(INTRO, "").strip
      words = value.split(" ")
      return nil if words.empty? || words.size > MAX_WORDS
      return nil unless words.all? { |w| w.match?(WORD) && w.length <= Studio::FIRST_NAME_MAX_LENGTH }
      return nil if words.size == 1 && NOT_NAMES.include?(words.first.downcase)
      return nil if value.length > Studio::FULL_NAME_MAX_LENGTH

      name = value == value.downcase ? words.map(&:capitalize).join(" ") : value
      Answer.new(kind: :name, name: name)
    end

    # Writes the name as the engine's onboarding step does; returns the stored first name.
    def save!(user, value)
      attrs = Studio::NameParts.from(value)
      attrs.delete(:last_name) unless user.respond_to?(:last_name)
      attrs[:name] = value if user.name.blank?
      user.update_columns(attrs)
      attrs[:first_name]
    end

    # Applies `answer` for `user` and returns the CTO's code reply.
    def reply!(user, answer)
      return "No problem. #{NEXT_STEP}" if answer.skip?

      "Nice to meet you, #{save!(user, answer.name)}! #{NEXT_STEP}"
    end
  end
end

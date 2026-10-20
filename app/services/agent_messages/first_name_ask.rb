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
  # still blank. When in doubt it routes to the model, never swallows (see
  # #parse and STOP_WORDS):
  #
  #   a name       "Ada", "Mary Jane", "I'm Ada Lovelace",    saved, answered in code;
  #                "call me jo"                               a strongly cued correction
  #                                                          ("call me Al") on the very
  #                                                          next message re-saves
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
    # An explicit cue that what follows is a name. Only after one may the name
    # run to MAX_WORDS words, typed in any case.
    # A STRONG cue ("call me", "my name is") admits any case; a WEAK one ("I'm",
    # "it's", "this is") opens ordinary sentences too ("I'm so excited", "It's
    # missing reviews"), so after it every word must be typed with a capital.
    STRONG_INTRO = /\A(?:(?:hi|hey|hello)[\s,!.]+)?(?:call me|my name is|my name'?s|name'?s)\s+/i
    WEAK_INTRO = /\A(?:(?:hi|hey|hello)[\s,!.]+)?(?:i'?m|i am|it'?s|its|this is)\s+/i
    WORD = /\A\p{L}[\p{L}\p{M}'’.-]*\z/u
    MAX_WORDS = 3
    # WHEN IN DOUBT, THE MODEL ANSWERS (Carl's review of this task: "Add dark
    # mode" was saved as a first name and the request never reached the model).
    # A reply with any of these words, lowercased, is not a name: the
    # acknowledgements and requests an owner types right after the greeting
    # ("Sounds good", "Make it blue", "Ship it"), function words, and the
    # app nouns a one-word request names ("Logo", "Pricing"). They reject a
    # cued reply too ("It's fine"), so a real name that collides ("Will") is
    # left to the model and /profile: a missed name costs less than a wrong one.
    STOP_WORDS = %w[
      yes yeah yep yup no nope ok okay k sure fine hi hey hello thanks thank thx ty please pls welcome
      good great perfect awesome cool nice love loved like liked looks look sounds sound amazing wow neat
      excellent beautiful lovely right correct exactly agreed agree done thing things lol haha hmm hm idk
      add make change go ship build let's lets let can could would will want need show fix update remove
      delete create start stop continue try use put set get give tell ask send keep move edit write run
      help explain plan ignore previous instructions instruction approve approved confirm proceed next
      it the a an my and or to of for in on with this that these those what's whats what why how who
      where when which is are was be do does did not me you your we our us i i'm im
      test testing name first last skip later
      logo color colors colour colours pricing price prices blog menu page pages site website app home
      booking bookings login signup dark light mode theme font fonts design layout gallery photos photo
      images image contact about footer header button buttons form forms payments payment shop store
      more again status details info question questions idea ideas feature features
    ].to_set.freeze
    CAPITAL = /\A\p{Lu}/u

    # `correction`: a cued name typed right after a saved one ("call me Al").
    Answer = Struct.new(:kind, :name, :correction, keyword_init: true) do
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

      newest_meta(thread_key)[META] == true
    end

    # THE SAFETY VALVE: right after a name was saved, the reply says how to fix
    # it, so the owner's next message may correct it, but only with a cue
    # ("call me Al", "my name is Ada"); anything else goes to the model.
    def correcting?(user, thread_key)
      user.respond_to?(:first_name) && newest_meta(thread_key)["first_name"] == "saved"
    end

    # The Answer for `user`'s message in `thread_key`, or nil (the model answers).
    def answer_for(user, thread_key, text)
      if pending?(user, thread_key) then parse(text)
      elsif correcting?(user, thread_key) then parse(text, cue_required: true)&.tap { |a| a.correction = true }
      end
    end

    def newest_meta(thread_key)
      meta = AgentMessage.where(channel: "web", thread_key: thread_key).order(id: :desc).pick(:run_meta)
      meta.is_a?(Hash) ? meta : {}
    end

    # The Answer `text` gives the ask, or nil when it is neither a name nor a
    # skip (nil: the model answers it). A name is, after a STRONG cue ("call
    # me", "my name is"), up to MAX_WORDS name-shaped words in any case; after
    # a WEAK cue ("I'm", "it's", "this is"), up to MAX_WORDS each typed with a
    # capital ("I'm Ada", not "I'm so excited"); with no cue, ONE word, or TWO
    # words each typed with a capital ("Mary Jane"). Any STOP_WORDS word rejects
    # it either way. `cue_required`: only a STRONG cue counts (a correction
    # after the name was saved: "It's missing reviews" is not one).
    def parse(text, cue_required: false)
      value = text.to_s.strip.gsub(/\s+/, " ").sub(/[.!]+\z/, "").strip
      return nil if value.empty? || value.length > Studio::FULL_NAME_MAX_LENGTH + 20
      return Answer.new(kind: :skip) if !cue_required && value.match?(SKIP)

      cue = if value.match?(STRONG_INTRO) then :strong
            elsif value.match?(WEAK_INTRO) then :weak
            end
      return nil if cue_required && cue != :strong

      value = value.sub(cue == :strong ? STRONG_INTRO : WEAK_INTRO, "").strip if cue
      words = value.split(" ")
      return nil unless name_words?(words, cue: cue)
      return nil if value.length > Studio::FULL_NAME_MAX_LENGTH

      name = value == value.downcase ? words.map(&:capitalize).join(" ") : value
      Answer.new(kind: :name, name: name)
    end

    def name_words?(words, cue:)
      return false if words.empty? || words.size > MAX_WORDS
      return false unless words.all? { |w| w.match?(WORD) && w.length <= Studio::FIRST_NAME_MAX_LENGTH }
      return false if words.any? { |w| STOP_WORDS.include?(w.downcase) }
      return true if cue == :strong
      return words.all? { |w| w.match?(CAPITAL) } if cue == :weak
      return true if words.size == 1

      words.size == 2 && words.all? { |w| w.match?(CAPITAL) }
    end

    # Writes the name as the engine's onboarding step does; returns the stored first name.
    # A correction replaces the name this ask wrote (its `name` still starts
    # with the first name it saved), and clears a surname the new one lacks.
    def save!(user, value, correction: false)
      attrs = Studio::NameParts.from(value)
      attrs[:last_name] ||= nil if correction
      attrs.delete(:last_name) unless user.respond_to?(:last_name)
      ours = correction && user.first_name.present? && user.name.to_s.start_with?(user.first_name.to_s)
      attrs[:name] = value if user.name.blank? || ours
      user.update_columns(attrs)
      attrs[:first_name]
    end

    # Applies `answer` for `user` and returns the CTO's code reply.
    def reply!(user, answer)
      return "No problem. #{NEXT_STEP}" if answer.skip?

      first = save!(user, answer.name, correction: answer.correction == true)
      return "Got it, #{first}. #{NEXT_STEP}" if answer.correction

      "Nice to meet you, #{first}! (Not right? Say \"call me\" and your name.) #{NEXT_STEP}"
    end
  end
end

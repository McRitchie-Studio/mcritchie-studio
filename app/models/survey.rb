# A feedback survey (task first-game-feedback-survey). Surveys are code, not
# rows: each is defined once in REGISTRY with its questions, and its answers are
# SurveyResponse rows that name it by slug. Adding a survey is adding an entry
# here; the public page (/s/:slug) and the admin view (/surveys/:slug) render
# whatever questions it lists.
#
# Question kinds:
#   faces     a 1..N scale shown as faces; `options` is [[value, emoji, label], ...]
#   choice    one of `options` ([[value, label], ...])
#   text      a short line of text (TEXT_LIMIT characters)
#   textarea  a longer note (TEXTAREA_LIMIT characters)
class Survey
  TEXT_LIMIT = 500
  TEXTAREA_LIMIT = 2000
  KINDS = %w[faces choice text textarea].freeze

  Question = Data.define(:key, :kind, :prompt, :required, :options) do
    def initialize(key:, kind:, prompt:, required: false, options: [])
      raise ArgumentError, "unknown question kind #{kind}" unless Survey::KINDS.include?(kind.to_s)

      super(key: key.to_s, kind: kind.to_s, prompt:, required:, options: options.freeze)
    end

    def values = options.map { |option| option.first.to_s }

    def text? = %w[text textarea].include?(kind)

    def limit = kind == "textarea" ? Survey::TEXTAREA_LIMIT : Survey::TEXT_LIMIT

    # The option row for a stored value, or nil.
    def option_for(value) = options.find { |option| option.first.to_s == value.to_s }
  end

  attr_reader :slug, :title, :intro, :questions, :play_url, :play_label

  def initialize(slug:, title:, intro:, questions:, play_url: nil, play_label: nil)
    @slug = slug
    @title = title
    @intro = intro
    @questions = questions.freeze
    @play_url = play_url
    @play_label = play_label
  end

  def to_param = slug

  def question(key) = questions.find { |q| q.key == key.to_s }

  def question_keys = questions.map(&:key)

  # The faces question whose distribution the admin view charts, if any.
  def feeling_question = questions.find { |q| q.kind == "faces" }

  def responses = SurveyResponse.where(survey_slug: slug)

  REGISTRY = [
    new(
      slug: "cyvasse-first-game",
      title: "Your first game on the new Cyvasse",
      intro: "Five quick questions. Alex reads every answer.",
      play_url: "https://cyvasse.xyz/",
      play_label: "Play another game",
      questions: [
        Question.new(key: "feeling", kind: "faces", required: true,
                     prompt: "How did your first game on the new Cyvasse feel?",
                     options: [ [ 1, "😞", "Rough" ], [ 2, "😕", "Meh" ], [ 3, "😐", "Okay" ],
                                [ 4, "🙂", "Good" ], [ 5, "🤩", "Loved it" ] ]),
        Question.new(key: "enjoyed", kind: "text", prompt: "What did you enjoy most?"),
        Question.new(key: "frustrated", kind: "text", prompt: "What frustrated or confused you?"),
        Question.new(key: "play_again", kind: "choice", prompt: "Would you play again?",
                     options: [ [ "yes", "Yes" ], [ "maybe", "Maybe" ], [ "no", "No" ] ]),
        Question.new(key: "anything_else", kind: "textarea", prompt: "Anything else for Alex?")
      ]
    )
  ].index_by(&:slug).freeze

  def self.all = REGISTRY.values

  def self.find_by(slug:) = REGISTRY[slug.to_s]

  # Raises ActiveRecord::RecordNotFound (a 404) for an unknown slug.
  def self.find(slug)
    find_by(slug:) || raise(ActiveRecord::RecordNotFound, "no survey #{slug.inspect}")
  end
end

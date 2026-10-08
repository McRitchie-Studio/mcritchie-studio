# frozen_string_literal: true

# DreamSelector — ranks dreams against one task. Pure: no file, board or clock.
#
# A dream scores on the tags it shares with the task: repo 3, risk 3, shape 2,
# stage 1, and 1 per topic word found in the task's title and acceptance, up to 3.
# A tag value the task does not carry scores 0. Ties rank in slug order.

module DreamSelector
  LIMIT = 12
  WEIGHTS = { "repo" => 3, "risk" => 3, "shape" => 2, "stage" => 1 }.freeze
  TOPIC_CAP = 3
  STOP_WORDS = %w[
    a an and are as at be before by can do does for from has have how in into is it its
    never no not of on once one only or so than that the their then this to when with
  ].freeze

  # What a task is scored on. `words` are its topic words.
  Task = Struct.new(:repo, :risk, :shape, :stage, :words, keyword_init: true)
  # `picked` is the soul's top dreams in rank order, `universals` the platform
  # sequence, `hidden` every other approved dream.
  Selection = Struct.new(:picked, :universals, :hidden, keyword_init: true) do
    def shown
      picked + universals
    end
  end

  module_function

  # A Task from the board's task JSON. Anything missing reads as empty.
  def task(facts)
    facts = {} unless facts.is_a?(Hash)
    metadata = facts["metadata"]
    devops = metadata.is_a?(Hash) ? metadata["devops"] : nil
    devops = {} unless devops.is_a?(Hash)
    Task.new(repo: tokens(devops["repositories"]),
             risk: tokens(devops["risk_tags"]),
             shape: tokens(devops["shape"]),
             stage: tokens(facts["stage"]),
             words: words([ facts["title"], *Array(devops["acceptance"]) ].join(" ")))
  end

  def tokens(value)
    Array(value).map { |item| item.to_s.strip.downcase }.reject(&:empty?)
  end

  # Lower-case words without stop words; a plural matches its singular.
  def words(text)
    text.to_s.downcase.scan(/[a-z0-9]+/).reject { |word| STOP_WORDS.include?(word) }.map { |word| stem(word) }.uniq
  end

  def stem(word)
    word.size > 3 ? word.delete_suffix("s") : word
  end

  def score(task, dream)
    tags = dream.tags
    tagged = WEIGHTS.sum { |tag, weight| (tokens(tags[tag]) & task[tag]).empty? ? 0 : weight }
    tagged + [ (words(Array(tags["topic"]).join(" ")) & task.words).size, TOPIC_CAP ].min
  end

  # Highest score first, then slug order.
  def rank(task, dreams)
    dreams.sort_by { |dream| [ -score(task, dream), dream.slug ] }
  end

  def select(task, dreams, soul:, limit: LIMIT)
    approved = dreams.select(&:approved?)
    picked = rank(task, approved.select { |dream| dream.souls.include?(soul) }).first(limit)
    universals = approved.select(&:platform?)
    Selection.new(picked: picked, universals: universals, hidden: approved - picked - universals)
  end
end

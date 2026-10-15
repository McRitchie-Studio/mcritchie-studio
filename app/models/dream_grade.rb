# frozen_string_literal: true

# A session's grade of one dream that fired in it (docs/agents/modules/dream.md,
# Act 4). At wrap, `bin/dream grade <slug> --score 0|1|2 --decision "..."` posts
# one, through POST /api/v1/dream_grades:
#
#   0  the dream fired and its answer was wrong for this case
#   1  it fired and helped
#   2  it fired and decided the outcome
#
# Only a dream that fired in the session can be graded: record! finds the session's
# newest `dream_fired` action for the slug (DreamHeat::KIND) and refuses without
# one. One grade per dream per session.
#
# A grade is agent-written data, not an approval. Nothing here reads or writes a
# dream file or its status; the swap ranking (DreamLoop) reads the mean.
class DreamGrade < ApplicationRecord
  SCORES = (0..2)
  DECISION_LIMIT = 160

  class NotGradable < StandardError; end

  belongs_to :agent_action, optional: true
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: :dream_grades
  include ClearsUnknownSlug
  clears_unknown_slug :task_slug, "Task"

  validates :dream_slug, :session_id, :decision, presence: true
  validates :score, inclusion: { in: SCORES }
  validates :decision, length: { maximum: DECISION_LIMIT }
  validates :dream_slug, uniqueness: { scope: :session_id }

  # Records the session's grade of the dream. Raises NotGradable unless the dream
  # fired in that session and is not graded there yet.
  def self.record!(session_id:, dream_slug:, score:, decision:)
    raise NotGradable, "a grade needs the session id" if session_id.blank?

    score = Integer(score.to_s, exception: false)
    raise NotGradable, "the score is 0, 1 or 2" unless SCORES.cover?(score)

    decision = decision.to_s.squish
    raise NotGradable, "a grade names the decision it judges" if decision.empty?

    fire = AgentAction.where(kind: DreamHeat::KIND, session_id: session_id.to_s, event_slug: dream_slug.to_s)
                      .order(occurred_at: :desc, id: :desc).first
    raise NotGradable, "`#{dream_slug}` did not fire in this session; only a dream that fired can be graded" unless fire
    if exists?(session_id: session_id.to_s, dream_slug: dream_slug.to_s)
      raise NotGradable, "`#{dream_slug}` is already graded in this session"
    end

    create!(session_id: session_id.to_s, dream_slug: dream_slug.to_s, score: score,
            decision: decision.first(DECISION_LIMIT), agent_action_id: fire.id,
            task_slug: fire.task_slug, mascot: fire.mascot)
  rescue ActiveRecord::RecordNotUnique
    raise NotGradable, "`#{dream_slug}` is already graded in this session"
  end

  Summary = Struct.new(:mean, :count, keyword_init: true)

  # { slug => Summary(mean, count) } in one grouped query; `slugs` narrows it.
  def self.summary(slugs = nil)
    scope = slugs ? where(dream_slug: slugs) : all
    scope.group(:dream_slug).pluck(:dream_slug, Arel.sql("AVG(score)"), Arel.sql("COUNT(*)"))
         .to_h { |slug, mean, count| [ slug, Summary.new(mean: mean.to_f.round(2), count: count.to_i) ] }
  end
end

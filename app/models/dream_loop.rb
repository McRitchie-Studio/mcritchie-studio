# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_layers").to_s

# The swap side of the dream loop (docs/agents/modules/dream.md, Act 4): how full a
# layer is, and which of its dreams the data says to swap out.
#
# A layer's ROOM is its budget (DreamLayers) less what it will hold once the queued
# sign-offs ship: its approved dreams, less those Alex McRitchie has retired (pending), plus
# the proposed ones he has approved (pending).
#
# The OUT candidates are the layer's approved dreams, not already retiring, past
# their grace, ranked:
#   1. lowest mean grade first (an ungraded dream counts as 1.0, the neutral grade);
#   2. then longest since its last fire (never fired first);
#   3. then slug.
#
# GRACE: a dream cannot be swapped out until it has loaded in GRACE_SESSIONS
# sessions since approval. Loads are not recorded, so the proxy is the number of
# distinct sessions that opened an activity since the dream was approved. Every
# session loads the platform layer; a soul's or a step's dreams load in fewer, so
# the proxy over-counts for them and ends their grace sooner. The approval time is
# the DreamApproval row's approved_at, else the date that opens the dream's
# `source:` line (a dream approved in chat), else none: a dream with neither
# predates the loop and is past grace.
class DreamLoop
  GRACE_SESSIONS = DreamLayers::GRACE_SESSIONS
  NEUTRAL_GRADE = 1.0
  SOURCE_DATE = /\A\s*(\d{4}-\d{2}-\d{2})/

  Candidate = Struct.new(:dream, :key, :mean_grade, :grades, :fires, :last_fired_at, :approved_since,
                         :sessions_since, :in_grace, :retiring, keyword_init: true) do
    def eligible? = !in_grace && !retiring

    def as_json(*)
      { dream_slug: dream.slug, dream_home: dream.home, key: key, question: dream.question,
        mean_grade: mean_grade, grades: grades, fires: fires, last_fired_at: last_fired_at&.iso8601,
        approved_since: approved_since&.iso8601, sessions_since_approval: sessions_since,
        in_grace: in_grace, retiring: retiring, eligible: eligible? }
    end
  end

  Report = Struct.new(:layer, :label, :budget, :approved, :retiring, :approving, :candidates, keyword_init: true) do
    def held = approved - retiring + approving
    def room = [ budget - held, 0 ].max
    def full? = room.zero?
    def eligible = candidates.select(&:eligible?)

    def as_json(*)
      { layer: layer, label: label, budget: budget, approved: approved, retiring: retiring,
        approving: approving, room: room, full: full?,
        candidates: eligible.map(&:as_json), ineligible: candidates.reject(&:eligible?).map(&:as_json) }
    end
  end

  def self.source_date(dream)
    match = SOURCE_DATE.match(dream.source.to_s)
    match && Time.zone.parse(match[1])
  rescue ArgumentError
    nil
  end

  def initialize(dreams)
    @dreams = Array(dreams)
    @sessions = {}
  end

  # One layer's report; nil for a key that is not a layer.
  def report(layer)
    return nil unless DreamLayers.valid?(layer)

    members = DreamLayers.members(@dreams, layer)
    retirements = (@retirements ||= DreamRetirement.pending_by_key(@dreams))
    approvals = (@approvals ||= DreamApproval.pending_by_key(@dreams))
    approving = @dreams.count do |dream|
      dream.status == DreamApproval::PROPOSED && approvals.key?(DreamApproval.key_for(dream)) &&
        DreamLayers.keys(dream).include?(layer)
    end
    Report.new(layer: layer, label: DreamLayers.label(layer), budget: DreamLayers.budget(layer),
               approved: members.size, approving: approving,
               retiring: members.count { |dream| retirements.key?(DreamApproval.key_for(dream)) },
               candidates: rank(candidates(members, retirements)))
  end

  # Every layer that holds an approved dream.
  def reports = DreamLayers.all(@dreams).map { |layer| report(layer) }

  private

  def candidates(members, retirements)
    slugs = members.map(&:slug)
    grades = DreamGrade.summary(slugs)
    fires = fire_stats(slugs)
    approved_at = DreamApproval.where(dream_slug: slugs).pluck(:dream_home, :dream_slug, :approved_at)
                               .to_h { |home, slug, at| [ "#{home}/#{slug}", at ] }
    members.map do |dream|
      key = DreamApproval.key_for(dream)
      since = approved_at[key] || self.class.source_date(dream)
      sessions = since ? sessions_since(since) : GRACE_SESSIONS
      Candidate.new(dream: dream, key: key, mean_grade: grades[dream.slug]&.mean, grades: grades[dream.slug]&.count.to_i,
                    fires: fires.dig(dream.slug, :count).to_i, last_fired_at: fires.dig(dream.slug, :last),
                    approved_since: since, sessions_since: sessions, in_grace: sessions < GRACE_SESSIONS,
                    retiring: retirements.key?(key))
    end
  end

  def rank(candidates)
    candidates.sort_by do |candidate|
      [ candidate.mean_grade || NEUTRAL_GRADE, candidate.last_fired_at&.to_f || 0.0, candidate.dream.slug ]
    end
  end

  # { slug => { count:, last: } } in one grouped query on the dream-fired index.
  def fire_stats(slugs)
    AgentAction.where(kind: DreamHeat::KIND, event_slug: slugs).group(:event_slug)
               .pluck(:event_slug, Arel.sql("COUNT(*)"), Arel.sql("MAX(occurred_at)"))
               .to_h { |slug, count, last| [ slug, { count: count, last: last } ] }
  end

  # Distinct sessions that opened an activity since `time`, counted up to the grace
  # (all the answer needs), so the read stays bounded.
  def sessions_since(time)
    @sessions[time] ||= AgentActivity.where(opened_at: time..).distinct.limit(GRACE_SESSIONS).pluck(:session_id).size
  end
end

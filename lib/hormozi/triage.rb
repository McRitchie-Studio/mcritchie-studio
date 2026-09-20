# frozen_string_literal: true

require "set"

module Hormozi
  # Scores one episode for how much MARKETING it teaches — the job Rex is hired
  # for.
  #
  # The corpus spans roughly 1,700 videos, and most of them are not about
  # marketing: hiring, firing, operations, mindset, morning routines, personal
  # stories. A CMO distilled from all of it evenly answers "what hook should
  # this ad open with?" with an anecdote about firing a manager. Tier 1 is what
  # earns a deep extraction pass; tier 3 stays metadata we can reach for later.
  module Triage
    # Terms that only show up when he is teaching demand: offers, leads,
    # content, brand, channels, and the numbers that govern them.
    CORE = %w[
      ad ads advertising affiliate audience brand branding cac campaign channel
      channels clicks content conversion convert copy copywriting cpm creative
      crm customers dm dms email engagement followers funnel funnels hook hooks
      inbound influencer instagram landing lead leads ltv magnet marketing
      messaging newsletter niche offer offers omnipresent organic outbound
      outreach page paid pitch positioning post posting reach referral referrals
      retargeting seo social subscribers tiktok traffic viral webinar youtube
    ].to_set.freeze

    # Adjacent commercial terms: real signal, but they also appear all over his
    # operations and mindset material, so they score lower.
    ADJACENT = %w[
      buy buyers churn client clients close closing customer demand deal
      discount growth launch model money monetize price prices pricing profit
      promotion rate retention revenue sales scale sell selling upsell value
    ].to_set.freeze

    # Terms that mark an episode as someone else's job. A title can still reach
    # tier 2 on strong core terms — these only pull it down.
    OFF_BRIEF = %w[
      accountability anxiety burnout confidence culture discipline divorce
      employee employees fire fired firing habits happiness hire hired hiring
      interview interviews lazy manage management manager managers meetings
      mindset motivation operations ops payroll productivity recruiting
      relationship relationships routine sleep staff team therapy training
      workout
    ].to_set.freeze

    # FORMAT IS AS LOAD-BEARING AS TOPIC. His highest-value teaching is a genre,
    # not a subject: "Building a $1,000,000 Business for a Stranger in 69
    # Minutes" is him running the whole diagnosis live on someone else's
    # business, and it carries no marketing noun at all — it scored zero and
    # landed in tier 3 next to the morning-routine videos. These patterns are
    # what a demonstration of the method looks like from the outside.
    FORMAT_PATTERNS = {
      "format:teardown" => /for a stranger|teardown|audit(ing)? (his|her|their|your)|helping a/i,
      "format:timeboxed" => /in \d+ (mins?|minutes)/i,
      "format:starting-over" => /if i (wanted|had|were|was)\b|start(ing)? over|from scratch/i,
      "format:masterclass" => /masterclass|\d+ years of|advice in \d+/i,
      "format:receipts" => /how (i|we) (gained|grew|built|got|made|turned)/i
    }.freeze

    CORE_POINTS = 3
    FORMAT_POINTS = 3
    ADJACENT_POINTS = 1
    OFF_BRIEF_POINTS = -2

    TIER_1_MIN = 3
    TIER_2_MIN = 1

    Result = Struct.new(:tier, :score, :matched, keyword_init: true)

    # Scores a title (and optional description) and returns the tier, the score,
    # and the terms that earned it, so a surprising tier can be explained rather
    # than argued with.
    def self.score(title, description = nil)
      core = []
      adjacent = []
      off_brief = []

      # Each token is counted ONCE, in the strongest list that claims it.
      # "customers" sits in CORE and stems to "customer" in ADJACENT; scoring
      # both banks a retention video 4 points for one word.
      tokenize([ title, description ].compact.join(" ")).each do |token|
        if listed?(CORE, token) then core << token
        elsif listed?(ADJACENT, token) then adjacent << token
        elsif listed?(OFF_BRIEF, token) then off_brief << token
        end
      end

      formats = FORMAT_PATTERNS.select { |_name, pattern| title.to_s.match?(pattern) }.keys

      total = (core.size * CORE_POINTS) +
              (formats.size * FORMAT_POINTS) +
              (adjacent.size * ADJACENT_POINTS) +
              (off_brief.size * OFF_BRIEF_POINTS)

      Result.new(tier: tier_for(total), score: total, matched: (core + formats).sort)
    end

    # Auto-captions and titles pluralize freely — "influencers" missed
    # "influencer" and dropped an influencer-marketing masterclass to tier 3.
    def self.listed?(list, token)
      list.include?(token) ||
        list.include?(token.sub(/s\z/, "")) ||
        list.include?("#{token}s")
    end

    def self.tier_for(total)
      return 1 if total >= TIER_1_MIN
      return 2 if total >= TIER_2_MIN

      3
    end

    def self.tokenize(text)
      text.to_s.downcase.scan(/[a-z]+/).to_set
    end
  end
end

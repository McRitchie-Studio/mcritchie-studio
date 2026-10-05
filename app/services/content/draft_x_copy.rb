class Content
  # Writes the copy for a video_post_x card from the team that won: one call to
  # X::PostDraft, then the text, the facts it read and anything worth a look are
  # saved on the card and it moves to `script` — ready for the operator.
  #
  # A draft that cannot be read (ESPN down, no team) leaves the card at `idea`
  # with the reason, where the Redraft button and the post-to-x SOP both find it.
  class DraftXCopy
    class Refused < StandardError; end

    class << self
      # The e2e lane's stand-in for the ESPN reads. nil means the real thing.
      attr_accessor :fetch
    end

    def initialize(content)
      @content = content
    end

    def call
      raise Refused, "only a Video Post (X) card is drafted this way" unless @content.video_post_x?
      raise Refused, "this card is already past its draft" unless %w[idea script].include?(@content.stage)

      team = Team.find_by(slug: @content.team_slug) or raise Refused, "pick the team that won"
      draft = X::PostDraft.new(
        team: X::PostDraft::Team.new(name: team.name, location: team.location, mascot: team.mascot, hashtag: team.hashtag),
        fetch: self.class.fetch
      ).call
      @content.update!(captions: draft.text, stage: "script", game_facts: draft.facts.merge("exceptions" => draft.exceptions))
      @content
    rescue X::PostDraft::Error => e
      @content.update!(game_facts: (@content.game_facts || {}).merge("draft_error" => e.message))
      @content
    end
  end
end

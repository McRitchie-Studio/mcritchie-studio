module Api
  module V1
    # The surface a SOUL works the content pipeline through.
    #
    # The non-deterministic steps — the take, the scenes, the caption — are
    # written by an agent during an SOP using its own inference, not by an
    # in-app call to the Anthropic API. That is the whole point: the judgment
    # belongs to a soul with brand context, and production needs no model key.
    #
    # The board is already the queue, so this adds no queue — only the reads,
    # the atomic claim, and the write-back that were missing.
    class ContentsController < BaseController
      before_action :set_content, only: [:show, :update, :release]

      # GET /api/v1/contents?stage=idea&workflow=game_recap&claimable=1
      # What is waiting for me. `claimable=1` hides cards another session holds.
      def index
        scope = Content.all
        scope = scope.by_stage(params[:stage]) if params[:stage].present?
        scope = scope.where(workflow: params[:workflow]) if params[:workflow].present?
        scope = scope.claimable_by_agent if params[:claimable].present?

        render_data(scope.ordered.limit(limit).map { |c| serialize(c) })
      end

      def show
        render_data(serialize(@content, full: true))
      end

      # POST /api/v1/contents/claim_next { session, agent, stage, workflow }
      #
      # The server picks WHICH content, mirroring the review pop. ALWAYS 200:
      # an empty queue is a normal outcome and the caller idles rather than
      # retry-storming.
      def claim_next
        result = nil
        rescue_and_log do
          result = Content.claim_next_for_agent(
            session:  claim_params[:session],
            agent:    claim_params[:agent],
            stage:    claim_params[:stage].presence || "idea",
            workflow: claim_params[:workflow]
          )
        end

        render_data({
          "claimed" => result.content && serialize(result.content, full: true),
          "reason"  => result.reason
        })
      end

      # PATCH /api/v1/contents/:slug
      #
      # The write-back. A soul sends what it wrote; `stage` advances the card.
      # Only the inference-authored fields are permitted — a claim cannot be
      # used to rewrite the scoreline the deterministic half recorded.
      def update
        rescue_and_log(target: @content) do
          @content.update!(content_params)
        end

        render_data(serialize(@content.reload, full: true))
      end

      # POST /api/v1/contents/:slug/release — "I am done, or I gave up."
      def release
        @content.release_claim!(session: params[:session])
        render_data(serialize(@content.reload, full: true))
      rescue ArgumentError => e
        render_error(e.message, status: :conflict, error_code: "CLAIM_HELD")
      end

      private

      def set_content
        @content = Content.find_by!(slug: params[:slug])
      end

      def limit
        [[params[:limit].to_i, 1].max, 100].min
      end

      def claim_params
        params.permit(:session, :agent, :stage, :workflow)
      end

      # Deliberately NARROW. `game_facts`, `game_slug`, `team_slug` and the
      # score columns are the deterministic half's record of what happened and
      # are not an agent's to edit — an agent that could rewrite the scoreline
      # could publish a video about a game that did not happen.
      def content_params
        params.require(:content).permit(
          :title, :description, :script_text, :duration_seconds, :captions,
          :music_track, :stage, :selected_hook_index,
          hook_ideas: [], hashtags: [], music_suggestions: [], caption_variants: [],
          # `scenes` is an array of HASHES, so its keys are named rather than
          # left as `scenes: []` — that form permits an array of SCALARS only and
          # silently drops every scene, which looks exactly like a model that
          # wrote nothing. Naming the keys also pins the contract the SOP writes to.
          scenes: [:number, :description, :camera, :duration, { characters: [] }]
          # `text_overlays` is deliberately NOT permitted: overlays are authored
          # by the deterministic assembly step, not by an agent's inference.
        )
      end

      def serialize(content, full: false)
        base = {
          slug:       content.slug,
          title:      content.title,
          stage:      content.stage,
          workflow:   content.workflow,
          claimed_by: content.claimed_by,
          claimed_at: content.claimed_at
        }
        return base unless full

        base.merge(
          description: content.description,
          game_slug:   content.game_slug,
          game_facts:  content.game_facts,
          team_slug:   content.team_slug,
          rival_team_slug: content.rival_team_slug,
          script_text: content.script_text,
          scenes:      content.scenes,
          captions:    content.captions,
          hashtags:    content.hashtags,
          url:         "#{ENV.fetch('STUDIO_BASE_URL', 'https://mcritchie.studio')}/contents/#{content.slug}"
        )
      end
    end
  end
end

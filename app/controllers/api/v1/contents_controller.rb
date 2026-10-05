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
      before_action :set_content, only: [:show, :update, :release, :posted]
      before_action :require_claim_holder, only: [:update, :posted]

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

      # PATCH /api/v1/contents/:slug { session, content: {...} }
      #
      # The write-back. A soul sends what it wrote; `stage` advances the card.
      # Only the inference-authored fields are permitted — a claim cannot be
      # used to rewrite the scoreline the deterministic half recorded.
      #
      # `session` is REQUIRED and is checked before the write (see
      # `require_claim_holder`). Without it this was the unguarded half of an
      # asymmetry: release — harmless — checked the session, and update —
      # destructive — did not.
      def update
        rescue_and_log(target: @content) do
          @content.update!(content_params)
        end

        render_data(serialize(@content.reload, full: true))
      end

      # POST /api/v1/contents/record_x_post { post_url, caption, title }
      #
      # ONE RECORD OF WHAT WENT OUT. A video posted from a file path with
      # bin/x-post has no card, so the board would not know it exists. This files
      # one, already at `posted`, carrying the link and the copy. It stores no
      # video and posts nothing: it is a ledger entry the board can show.
      # Idempotent on the link, so a re-run files nothing twice.
      def record_x_post
        url     = params[:post_url].to_s.strip
        post_id = url[%r{\Ahttps://(?:x|twitter)\.com/[A-Za-z0-9_]+/status/(\d+)\z}, 1]
        return render_error("post_url must be an x.com status URL", status: :unprocessable_entity, error_code: "BAD_POST_URL") if post_id.nil?

        content = Content.find_by(workflow: "video_post_x", post_id: post_id)
        content ||= Content.create!(
          title: params[:title].to_s.squish.presence || params[:caption].to_s.squish.truncate(60).presence || "X post #{post_id}",
          workflow: "video_post_x", stage: "posted", platform: "x", source_type: "manual",
          captions: params[:caption].to_s.presence, post_url: url, post_id: post_id, posted_at: Time.current
        )
        render_data(serialize(content, full: true))
      end

      # POST /api/v1/contents/:slug/posted { session, post_url }
      #
      # "It is live." Records where a video_post_x card was posted, moves it to
      # `posted` and lets the claim go. Narrow on purpose: post_url is not in the
      # general write-back, so a claim on any other workflow cannot mark a card
      # posted that nothing posted. The id is read out of the URL, so the two
      # cannot disagree.
      def posted
        return render_error("only a video_post_x card is recorded this way", status: :unprocessable_entity, error_code: "WRONG_WORKFLOW") unless @content.video_post_x?

        return render_error("this card is already posted: #{@content.post_url}", status: :conflict, error_code: "ALREADY_POSTED") if @content.stage == "posted"

        post_id = params[:post_url].to_s[%r{\Ahttps://(?:x|twitter)\.com/[A-Za-z0-9_]+/status/(\d+)\z}, 1]
        return render_error("post_url must be an x.com status URL", status: :unprocessable_entity, error_code: "BAD_POST_URL") if post_id.nil?

        rescue_and_log(target: @content) do
          Content::Post.new(@content).call(platform: "x", post_url: params[:post_url], post_id: post_id)
          @content.release_claim!(session: params[:session])
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

      # THE LEASE, ENFORCED. 409 rather than 403: nothing is wrong with the
      # caller's credential — the card's claim state conflicts with the write,
      # and the remedy is to claim it (again), not to re-authenticate. The code
      # says which of the three states it found so a caller can act on it
      # without parsing prose.
      def require_claim_holder
        refusal = @content.claim_write_refusal(session: params[:session])
        return if refusal.nil?

        render_error(refusal.message, status: :conflict, error_code: refusal.code)
      end

      # An absent `limit` must show the QUEUE, not one card: `to_i` on a missing
      # param is 0, so the floor meant to guard `limit=0` became the DEFAULT.
      def limit
        given = params[:limit].to_i
        return 50 if given <= 0

        [given, 100].min
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
          # The rapper-replace cast, so an agent (or the upstream duo detector)
          # can set who the piece is about. game_facts and the score columns
          # stay unwritable — those are the deterministic half's record.
          :qb_player_slug, :skill_player_slug, :colorway,
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
          final_video_url: content.final_video_url,
          post_url:    content.post_url,
          url:         "#{ENV.fetch('STUDIO_BASE_URL', 'https://mcritchie.studio')}/contents/#{content.slug}"
        )
      end
    end
  end
end

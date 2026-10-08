module Api
  module V1
    # The chat door of the tiktok-draft SOP (recast pipeline, piece 19), as
    # bin/tiktok-draft drives it. The clip card's "Draft to TikTok" button is
    # the other door into the same machine (Tiktok::DraftClip).
    #
    #   GET  /api/v1/alt_video_clips/:slug/tiktok_drafts   the clip, what a draft would send, every attempt
    #   POST /api/v1/alt_video_clips/:slug/tiktok_drafts   record an attempt and queue the upload (201);
    #                                                      dry_run=true answers the preview and writes nothing
    #   POST /api/v1/tiktok_drafts/:id/refresh             read TikTok's status once more
    #   GET  /api/v1/tiktok/creator_info                   which TikTok account the server's keys post as
    #
    # CREATING A DRAFT NEEDS AN ADMIN SESSION (piece 22). It puts a video on the
    # operator's phone, so a bearer that merely proves "an agent" is not enough:
    # the shared secret's token and a studio session both answer 403, and the
    # refusal says how the admin session is granted. bin/tiktok-draft's --yes is
    # a prompt for the agent; this is the guard. Reading (the index, a dry run,
    # a status refresh, the probe) stays open to any board bearer.
    class TiktokDraftsController < BaseController
      ADMIN_SESSION_HINT = "An admin soul (xan or steffon) asks the board for one with `bin/agent-activity heartbeat xan`, " \
                           "the operator grants it on the tasks page, and bin/tiktok-draft presents it. When the board " \
                           "cannot grant, a shell on this hub can: `bin/rails agent_sessions:grant_admin` prints a token " \
                           "that bin/tiktok-draft reads from AGENT_ADMIN_SESSION_TOKEN. The clip card's Draft to TikTok " \
                           "button is the other door".freeze

      require_admin_session_only only: :create, unless: :dry_run?
      before_action :set_clip, only: %i[index create]

      def index
        render_data({ "clip" => clip_data, "preview" => preview_data, "attempts" => @clip.tiktok_drafts.map(&:as_report) })
      end

      def create
        service = Tiktok::DraftClip.new
        return render_data({ "clip" => clip_data, "preview" => present(service.preview(@clip)), "dry_run" => true }) if dry_run?

        preview = service.check!(@clip) # a refusal is an answer, not an ErrorLog
        refusal = nil
        draft = rescue_and_log(target: @clip) do
          service.record!(preview, by: requested_by)
        rescue Tiktok::DraftClip::Refused => e # the second of two requests, refused under the lock
          refusal = e
        end
        raise refusal if refusal

        render_data(draft.as_report, status: :created)
      rescue Tiktok::DraftClip::Refused => e
        render_error(e.message, status: :conflict, error_code: "NOT_DRAFTABLE")
      end

      def refresh
        draft = TiktokDraft.find(params[:id])
        rescue_and_log(target: draft) { Tiktok::DraftClip.new.refresh(draft) }
        render_data(draft.as_report)
      end

      # The probe: refresh the token and ask TikTok who it is. Never answers a token.
      def creator_info
        unless Tiktok::OAuthClient.runtime_creds_present?
          return render_error(Tiktok::DraftClip.unavailable_reason, status: :service_unavailable, error_code: "NOT_CONFIGURED")
        end

        data = Tiktok::InboxUpload.new.creator_info
        render_data(data.slice("creator_username", "creator_nickname", "privacy_level_options",
                               "max_video_post_duration_sec", "comment_disabled", "duet_disabled", "stitch_disabled"))
      rescue Tiktok::InboxUpload::Error, Tiktok::OAuthClient::Error => e
        render_error(e.message.gsub(/"(access|refresh)_token"\s*:\s*"[^"]*"/, '"\1_token":"[redacted]"'),
                     status: :bad_gateway, error_code: "TIKTOK_REFUSED")
      end

      private

      # The gate and the action read this ONE predicate, so a request is either a
      # dry run (the preview, nothing written) or a gated draft, never between.
      def dry_run? = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) == true

      # Who asked: the admin session's soul, with the door it came through.
      def requested_by
        [current_agent_session&.soul, params[:requested_by].presence || "bin/tiktok-draft"].compact.join(" via ")
      end

      def admin_session_hint = ADMIN_SESSION_HINT

      def set_clip
        @clip = AltVideoClip.includes(:versions, :tiktok_drafts, alt_video: :music_video).find_by!(slug: params[:alt_video_clip_slug])
      end

      def clip_data
        primary = @clip.primary_version
        { "slug" => @clip.slug, "name" => @clip.name, "alt_video" => @clip.alt_video_slug,
          "primary_version" => primary&.number, "available" => Tiktok::DraftClip.available?,
          "stand_in" => Tiktok::DraftClip.stand_in? }
      end

      def preview_data
        present(Tiktok::DraftClip.new.preview(@clip))
      rescue Tiktok::DraftClip::Refused => e
        { "refused" => e.message }
      end

      def present(pv)
        { "version_number" => pv.version.number, "byte_size" => pv.version.byte_size, "athlete" => pv.choice.entry.person_name,
          "look" => pv.choice.entry.look_name, "athlete_rule" => pv.choice.rule, "team" => pv.choice.team.name,
          "team_from" => pv.choice.team_source, "caption" => pv.caption.text,
          "caption_length" => Tiktok::ClipCaption.length(pv.caption.text), "facts" => pv.caption.facts,
          "exceptions" => pv.caption.exceptions }
      end
    end
  end
end

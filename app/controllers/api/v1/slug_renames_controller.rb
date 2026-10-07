module Api
  module V1
    # PATCH /api/v1/slugs/:kind/:slug { "slug_to": "<new slug>" }
    #
    # Renames one record's slug with every row that names it (Sluggable#rename_slug!,
    # one transaction). Admin sessions only. 200 answers the new slug and the rows
    # each child column moved; a refusal (blank, badly formed, taken) answers 422
    # with the reason and error_code SLUG_REFUSED.
    class SlugRenamesController < BaseController
      require_admin_session

      # The kinds a slug can be renamed for. Agents, apps and users are absent on
      # purpose: their slugs are also config and tooling handles
      # (config/souls.yml, config/apps.yml, session keys), which no rename reaches.
      KINDS = {
        "people" => "Person", "teams" => "Team", "athletes" => "Athlete", "coaches" => "Coach",
        "arenas" => "Arena", "seasons" => "Season", "slates" => "Slate", "games" => "Game",
        "depth_charts" => "DepthChart", "skills" => "Skill"
      }.freeze

      def update
        model = KINDS[params[:kind]]&.constantize
        return render_error("unknown kind #{params[:kind].inspect}; one of #{KINDS.keys.join(", ")}", error_code: "UNKNOWN_KIND") unless model

        record = model.find_by!(slug: params[:slug])
        from = record.slug
        cascaded = record.rename_slug!(params.require(:slug_to))
        render_data({ kind: params[:kind], from: from, slug: record.slug, cascaded: cascaded })
      rescue Sluggable::SlugRefused => e
        render_error(e.record.errors.full_messages_for(:slug).to_sentence, error_code: "SLUG_REFUSED")
      rescue ActionController::ParameterMissing
        render_error("slug_to is required: the new slug", error_code: "SLUG_REFUSED")
      end
    end
  end
end

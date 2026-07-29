class ContentsController < ApplicationController
  # The `reorder` action, its `slugs` guard, the 100-gap restamp (delegated to
  # Content's Studio::Board::Rankable#reposition!), and the ErrorLog-logging + 422 net
  # all come from the shared board primitive concern. The board POSTs { slugs: [...],
  # zone: "<stage>" }; the action reads only `slugs`. require_admin still gates it.
  include Studio::Board::Reorderable
  board_reorderable model: Content, id_attr: :slug, param: :slugs

  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
  skip_before_action :require_authentication, only: [:index, :show]
  before_action :require_admin, except: [:index, :show]
  before_action :set_content, only: [:show, :edit, :update, :destroy, :hook_step, :script_step, :assets_step, :assemble_step, :post_step, :review_step, :script_agent_step, :assets_agent_step, :assemble_agent_step, :finalize_step, :metadata_step, :generate_lineup_assets, :post_to_x, :post_to_tiktok, :prep_for_tiktok, :use_caption_variant, :mark_posted, :studio_upload_to_tiktok]

  def index
    @contents = Content.ordered
    @contents_by_stage = @contents.group_by(&:stage)
  end

  def show
  end

  def new
    @content = Content.new
  end

  def create
    @content = Content.new(content_params)
    rescue_and_log(target: @content) do
      @content.save!
      redirect_to content_path(@content.slug), notice: "Content idea created."
    end
  rescue StandardError => e
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def generate_lineup_assets
    rescue_and_log(target: @content) do
      allowed = %w[starter_post_x starter_post_tiktok_offense starter_post_tiktok_defense]
      raise "Only available for lineup-graphic workflows" unless allowed.include?(@content.workflow)
      Content::GenerateLineupAssets.new(@content).call
      redirect_to content_path(@content.slug), notice: "Lineup assets generated and uploaded to S3."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: "Asset generation failed: #{e.message}"
  end

  def post_to_x
    rescue_and_log(target: @content) do
      raise "Only available for starter_post_x content" unless @content.workflow == "starter_post_x"
      Content::PostToX.new(@content).call
      redirect_to content_path(@content.slug), notice: "Posted to X."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: "Post to X failed: #{e.message}"
  end

  def post_to_tiktok
    rescue_and_log(target: @content) do
      raise "Only available for TikTok workflows" unless @content.tiktok_workflow?
      Content::PostToTiktok.new(@content, publish_type: params[:publish_type], music_id: params[:music_id]).call
      redirect_to content_path(@content.slug), notice: "Posted to TikTok."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: "Post to TikTok failed: #{e.message}"
  end

  def studio_upload_to_tiktok
    rescue_and_log(target: @content) do
      raise "Only available for TikTok workflows" unless @content.tiktok_workflow?
      result = Tiktok::StudioUpload.new(@content).call
      redirect_to content_path(@content.slug), notice: "🤖 Browser opening with video + caption pre-loaded. Review and click Post in TikTok Studio. (pid #{result[:pid]})"
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: "Studio upload failed: #{e.message}"
  end

  def prep_for_tiktok
    rescue_and_log(target: @content) do
      raise "Only available for TikTok workflows" unless @content.tiktok_workflow?
      raise "Content must be in assets stage (currently #{@content.stage})" unless @content.stage == "assets"
      Content::PrepForTiktok.new(@content).call
      redirect_to content_path(@content.slug), notice: "Prepped for post — pick a caption and click Begin Post."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: "Prep failed: #{e.message}"
  end

  def use_caption_variant
    rescue_and_log(target: @content) do
      idx = params[:index].to_i
      variants = Array(@content.caption_variants)
      raise "Variant index #{idx} out of range" unless idx.between?(0, variants.length - 1)
      @content.update!(captions: variants[idx])
      redirect_to content_path(@content.slug), notice: "Caption updated to variant #{idx + 1}."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def mark_posted
    rescue_and_log(target: @content) do
      raise "Content must be in assembly or assets stage (currently #{@content.stage})" unless %w[assets assembly].include?(@content.stage)
      Content::Post.new(@content).call(
        platform: params[:platform].presence || (@content.tiktok_workflow? ? "tiktok" : nil),
        post_url: params[:post_url].presence,  # nil OK — user can paste later via Edit
        post_id:  params[:post_id].presence
      )
      redirect_to content_path(@content.slug), notice: "Marked as posted. Paste the URL later via Edit if you want to track it."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def create_starter_post_x
    team = Team.find_by(slug: params[:team_slug])
    return redirect_to nfl_rosters_path, alert: "Team not found" unless team

    mascot = team.name.split.last
    suffix = [team.hashtag, team.emoji].compact_blank.join(" ")
    body   = "Find the mistake in my #{mascot} lineup 👀"
    body   = "#{body}\n\n#{suffix}" if suffix.present?

    @content = Content.new(
      workflow: "starter_post_x",
      team_slug: team.slug,
      title: "#{team.name} — find the mistake",
      description: "Starter Post (X) for #{team.name}.",
      stage: "script",
      source_type: "studio",
      captions: body
    )
    rescue_and_log(target: @content) do
      @content.save!
      redirect_to edit_content_path(@content.slug), notice: "Starter Post created for #{team.name}."
    end
  rescue StandardError => e
    redirect_to nfl_rosters_path, alert: e.message
  end

  def create_starter_post_tiktok_offense
    create_tiktok_starter_post("starter_post_tiktok_offense", "OFFENSE", "🚨")
  end

  def create_starter_post_tiktok_defense
    create_tiktok_starter_post("starter_post_tiktok_defense", "DEFENSE", "🛡️")
  end

  def update
    rescue_and_log(target: @content) do
      @content.update!(content_params)
      respond_to do |format|
        format.html { redirect_to content_path(@content.slug), notice: "Content updated." }
        format.json { render json: @content }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { render :edit, status: :unprocessable_entity }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def destroy
    rescue_and_log(target: @content) do
      @content.destroy!
      respond_to do |format|
        format.html { redirect_to contents_path, notice: "Content deleted." }
        format.json { head :no_content }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to contents_path, alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end


  def hook_step
    rescue_and_log(target: @content) do
      raise "Content must be in idea stage" unless @content.stage == "idea"

      Content::Hook.new(@content).call(
        hook_image_url: params[:hook_image_url],
        hook_ideas: params[:hook_ideas],
        selected_hook_index: params[:selected_hook_index]&.to_i
      )
      redirect_to content_path(@content.slug), notice: "Hook created."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def script_step
    rescue_and_log(target: @content) do
      raise "Content must be in hook stage" unless @content.stage == "hook"

      Content::Script.new(@content).call(
        script_text: params[:script_text],
        duration_seconds: params[:duration_seconds]&.to_i,
        scenes: params[:scenes]
      )
      redirect_to content_path(@content.slug), notice: "Script written."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def assets_step
    rescue_and_log(target: @content) do
      raise "Content must be in script stage" unless @content.stage == "script"

      Content::Assets.new(@content).call(
        scene_assets: params[:scene_assets]
      )
      redirect_to content_path(@content.slug), notice: "Assets generated."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def assemble_step
    rescue_and_log(target: @content) do
      raise "Content must be in assets stage" unless @content.stage == "assets"

      Content::Assemble.new(@content).call(
        final_video_url: params[:final_video_url],
        music_track: params[:music_track],
        text_overlays: params[:text_overlays],
        logo_overlay: params[:logo_overlay]
      )
      redirect_to content_path(@content.slug), notice: "Video assembled."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def post_step
    rescue_and_log(target: @content) do
      # Lineup-graphic workflows skip the AI assembly step (the captured MP4 is final at the assets stage).
      lineup_workflows = %w[starter_post_x starter_post_tiktok_offense starter_post_tiktok_defense]
      allowed_stages = lineup_workflows.include?(@content.workflow) ? %w[assets assembly] : %w[assembly]
      unless allowed_stages.include?(@content.stage)
        raise "Content must be in #{allowed_stages.join(' or ')} stage (currently #{@content.stage})"
      end

      url = params[:post_url].to_s.strip
      raise "post URL required" if url.blank?

      default_platform = case @content.workflow
                         when "starter_post_x"                                       then "x"
                         when "starter_post_tiktok_offense", "starter_post_tiktok_defense" then "tiktok"
                         end
      platform = params[:platform].presence || default_platform
      post_id  = params[:post_id].presence || extract_post_id(url, platform)

      Content::Post.new(@content).call(
        platform: platform,
        post_url: url,
        post_id: post_id
      )
      redirect_to content_path(@content.slug), notice: "Marked as posted."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def review_step
    rescue_and_log(target: @content) do
      raise "Content must be in posted stage" unless @content.stage == "posted"

      Content::Review.new(@content).call(
        views: params[:views]&.to_i,
        likes: params[:likes]&.to_i,
        comments_count: params[:comments_count]&.to_i,
        shares: params[:shares]&.to_i,
        review_notes: params[:review_notes]
      )
      redirect_to content_path(@content.slug), notice: "Content reviewed."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def script_agent_step
    rescue_and_log(target: @content) do
      raise "Content must be in hook stage" unless @content.stage == "hook"

      Content::ScriptAgent.new(@content).call
      redirect_to content_path(@content.slug), notice: "Script generated by AI."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def assets_agent_step
    rescue_and_log(target: @content) do
      raise "Content must be in script stage" unless @content.stage == "script"

      Content::AssetsAgent.new(@content).call
      redirect_to content_path(@content.slug), notice: "Assets generated by AI."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def assemble_agent_step
    rescue_and_log(target: @content) do
      raise "Content must be in assets stage" unless @content.stage == "assets"

      Content::AssembleAgent.new(@content).call
      redirect_to content_path(@content.slug), notice: "Video assembled by AI."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def finalize_step
    rescue_and_log(target: @content) do
      raise "Content must be in assembly stage" unless @content.stage == "assembly"

      Content::Finalize.new(@content).call
      redirect_to content_path(@content.slug), notice: "Video finalized with watermark."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  def metadata_step
    rescue_and_log(target: @content) do
      Content::MetadataAgent.new(@content).call
      redirect_to content_path(@content.slug), notice: "Metadata generated — captions, hashtags, music."
    end
  rescue StandardError => e
    redirect_to content_path(@content.slug), alert: e.message
  end

  private

  def create_tiktok_starter_post(workflow, side_label, emoji)
    team = Team.find_by(slug: params[:team_slug])
    return redirect_to nfl_rosters_path, alert: "Team not found" unless team

    mascot = team.name.split.last
    body   = "Find the mistake on my #{mascot} #{side_label} #{emoji}"
    suffix = [team.hashtag, team.emoji].compact_blank.join(" ")
    body   = "#{body}\n\n#{suffix}" if suffix.present?

    @content = Content.new(
      workflow:    workflow,
      team_slug:   team.slug,
      title:       "#{team.name} — #{side_label.downcase} mistake",
      description: "Starter Post (TikTok #{side_label.capitalize}) for #{team.name}.",
      stage:       "script",
      source_type: "studio",
      captions:    body
    )
    rescue_and_log(target: @content) do
      @content.save!
      redirect_to edit_content_path(@content.slug), notice: "TikTok #{side_label.capitalize} Starter Post created for #{team.name}."
    end
  rescue StandardError => e
    redirect_to nfl_rosters_path, alert: e.message
  end

  def extract_post_id(url, platform)
    case platform
    when "x"      then url.to_s.match(%r{/status/(\d+)})&.captures&.first
    when "tiktok" then url.to_s.match(%r{/video/(\d+)})&.captures&.first
    end
  end

  def set_content
    @content = Content.find_by(slug: params[:slug])
    return redirect_to contents_path, alert: "Content not found" unless @content
  end

  def content_params
    params.require(:content).permit(
      :title, :description, :source_type, :source_news_slug, :content_type, :stage,
      :hook_image_url, :selected_hook_index,
      :script_text, :duration_seconds,
      :final_video_url, :music_track, :logo_overlay,
      :platform, :post_url, :post_id,
      :views, :likes, :comments_count, :shares, :review_notes,
      :reference_video_url, :reference_video_start, :reference_video_end,
      :rival_team_slug, :captions,
      :workflow, :team_slug,
      hashtags: [], music_suggestions: []
    )
  end
end

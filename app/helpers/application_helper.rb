module ApplicationHelper
  def qa_environment?
    ENV["QA_ENV"].to_s.strip.downcase == "true"
  end

  def show_environment_banner?(qa_environment: qa_environment?, rails_env: Rails.env)
    !rails_env.production? || qa_environment
  end

  def environment_banner_message(qa_environment: qa_environment?, rails_env: Rails.env)
    return "QA Environment · Non-production" if qa_environment

    "#{rails_env.to_s.capitalize} Environment"
  end

  def stage_scheme(stage)
    case stage.to_s
    when "new"                         then "info"
    when "queued", "pr_review"         then "warning"
    when "in_progress", "qa_review"    then "success"
    when "prod_ready", "done"          then "success"
    when "failed"                      then "danger"
    else "neutral"
    end
  end

  def task_stage_count_classes(stage)
    case stage.to_s
    when "new"         then "bg-blue-900/50 text-blue-300"
    when "queued"      then "bg-yellow-900/50 text-yellow-300"
    when "in_progress" then "bg-mint-900/50 text-mint-300"
    when "pr_review"   then "bg-orange-900/50 text-orange-300"
    when "qa_review"   then "bg-cyan-900/50 text-cyan-300"
    when "prod_ready"  then "bg-violet-900/50 text-violet-300"
    when "done"        then "bg-green-900/50 text-green-300"
    when "failed"      then "bg-red-900/50 text-red-300"
    when "archived"    then "bg-surface-alt text-muted"
    else "bg-surface-alt text-muted"
    end
  end

  def news_stage_scheme(stage)
    case stage.to_s
    when "new"        then "stage-fresh"
    when "reviewed"   then "stage-shaping"
    when "processed"  then "stage-structured"
    when "refined"    then "stage-refined"
    when "concluded"  then "stage-cohered"
    when "archived"   then "stage-closed"
    else "neutral"
    end
  end
end

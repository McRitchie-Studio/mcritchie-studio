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
    when "new"         then "info"
    when "queued"      then "warning"
    when "in_progress" then "success"
    when "done"        then "success"
    when "failed"      then "danger"
    else "neutral"
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

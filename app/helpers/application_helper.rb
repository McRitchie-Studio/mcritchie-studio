module ApplicationHelper
  NON_DELIVERING_EMAIL_METHODS = %w[test file].freeze

  def email_delivery_banner_status
    delivery_method = ActionMailer::Base.delivery_method.to_s
    capture_enabled = Studio.local_email_capture?
    sends_email = ActionMailer::Base.perform_deliveries && !capture_enabled &&
                  !NON_DELIVERING_EMAIL_METHODS.include?(delivery_method)

    "EMAIL SEND #{sends_email} · #{email_delivery_transport_label(delivery_method, capture_enabled)}"
  end

  def email_delivery_transport_label(delivery_method = ActionMailer::Base.delivery_method.to_s,
                                     capture_enabled = Studio.local_email_capture?)
    return "capture" if capture_enabled
    return "ses" if Studio.ses_transport_ready?
    return "resend" if delivery_method == "resend"

    delivery_method.presence || "unknown"
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

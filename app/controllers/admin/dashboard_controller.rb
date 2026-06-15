module Admin
  class DashboardController < ApplicationController
    USER_LIMIT = 25
    REQUEST_LOG_LIMIT = 25

    before_action :require_admin

    def show
      @users = User.with_attached_avatar.order(created_at: :desc).limit(USER_LIMIT)
      @user_count = User.count
      @admin_count = User.where(role: "admin").count

      @request_logs = ErrorLog.order(created_at: :desc).limit(REQUEST_LOG_LIMIT)
      @request_log_count = ErrorLog.count
    end
  end
end

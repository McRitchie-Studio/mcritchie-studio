require "test_helper"

# Guards the engine baseline carried in app/models/current.rb. studio-engine's
# set_current_context does `Current.user = current_user` on every authenticated
# request; because the non-isolated engine lets the host's Current REPLACE the
# gem's wholesale, the host file MUST declare `attribute :user` or that
# assignment is silently dropped (and a Current.user reader would return nil).
# This exercises the real request path so blocker 1 can't regress unseen.
class CurrentUserContextTest < ActionDispatch::IntegrationTest
  # [integration] an authenticated request populates Current.user via the engine's
  # set_current_context before_action.
  test "an authenticated web request populates Current.user" do
    user = users(:alex)
    log_in_as(user)

    # Current resets at the end of the request, so capture it WHILE the action is
    # processing (the notification fires synchronously, before the executor reset).
    captured = :unset
    probe = ->(*) { captured = Current.user }
    ActiveSupport::Notifications.subscribed(probe, "process_action.action_controller") do
      get tasks_path
    end

    assert_response :success
    refute_equal :unset, captured, "process_action never fired — the probe did not run"
    assert_not_nil captured,
                   "set_current_context must populate Current.user — " \
                   "app/models/current.rb must carry the engine's `attribute :user`"
    assert_equal user.id, captured.id
  end
end

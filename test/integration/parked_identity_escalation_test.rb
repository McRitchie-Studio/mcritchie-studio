# frozen_string_literal: true

require "test_helper"

# [integration] A member cannot become an admin by typing a parked address on /profile.
class ParkedIdentityEscalationTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:viewer)
    log_in_as @member
  end

  def walled = (get("/tasks"); response.status)

  test "a case variant of a held admin address is refused and grants nothing" do
    patch "/profile", params: { profile: { email: users(:alex).email.capitalize } }

    refute @member.reload.admin?
    refute_equal users(:alex).email.capitalize, @member.email
    assert_equal 302, walled
  end

  test "an unheld parked address is saved unproven and grants nothing" do
    patch "/profile", params: { profile: { email: "admin@mcritchie.studio" } }

    refute @member.reload.admin?
    assert_nil @member.email_verified_at
    assert_equal 302, walled
  end
end

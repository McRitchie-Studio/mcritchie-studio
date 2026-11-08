# frozen_string_literal: true

require "test_helper"

# [integration] A member cannot become an admin by typing a parked address on /profile.
class ParkedIdentityEscalationTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:viewer)
    log_in_as @member
  end

  def walled = (get("/devops/tasks"); response.status)

  test "a case variant of a held admin address is refused and grants nothing" do
    patch "/profile", params: { profile: { email: users(:alex).email.capitalize } }

    refute @member.reload.admin?
    refute_equal users(:alex).email.capitalize, @member.email
    assert_equal 302, walled
  end

  test "an unheld parked address is refused, so the owner's first sign-in cannot promote a squatter" do
    patch "/profile", params: { profile: { email: "admin@mcritchie.studio" } }

    refute_equal "admin@mcritchie.studio", @member.reload.email
    refute @member.admin?

    owner_session = open_session
    token = Studio::Link.create_magic_link(email: "admin@mcritchie.studio").token
    owner_session.post link_consume_path(token: token)

    owner = User.find_by!(email: "admin@mcritchie.studio")
    refute_equal @member.id, owner.id, "the owner gets a fresh row"
    assert owner.admin?
    refute @member.reload.admin?
    assert_equal 302, walled, "the member's own cookie gains nothing"
  end

  test "a mixed-case address on /profile is saved so its owner can sign in again" do
    patch "/profile", params: { profile: { email: "Bob.Smith@Example.com" } }
    assert_equal "bob.smith@example.com", @member.reload.email

    other = open_session
    other.post link_consume_path(token: Studio::Link.create_magic_link(email: "bob.smith@example.com").token)
    assert_equal 1, User.where(email: "bob.smith@example.com").count, "the link finds the row and makes no second account"
  end
end

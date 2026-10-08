require "test_helper"

# [unit] [integration] NO HUB USER CAN SIGN IN BY PASSWORD.
#
# The hub is passwordless by policy (config/initializers/studio.rb auth_methods:
# magic link + Google), yet production held password digests for 3 of its 8 users
# (counted read-only on 2026-10-06), and studio-engine up to 0.90 draws
# POST /login -> sessions#create, which calls `user.authenticate(params[:password])`.
# While User kept has_secure_password, anyone who knew or guessed one of those
# passwords could sign in as that user, limited only by a rack-attack throttle.
#
# Closed three ways, each enough on its own:
#   1. User has no has_secure_password, so there is no `authenticate` to call;
#   2. no row holds a digest, and User ignores the column;
#   3. AdminWall keeps sessions#create off its PUBLIC list (wall-drops-password-login).
#
# The engine either draws POST /login (0.88, 0.90) or does not (studio-engine
# PR 420). The tests below hold on both: a drawn route answers a visitor with the
# wall's sign-in redirect, an undrawn one with 404, and in neither does the
# session gain a user.
class PasswordLoginClosedTest < ActionDispatch::IntegrationTest
  ONCE_VALID = "correct horse battery staple".freeze
  # BCrypt of ONCE_VALID at cost 4, minted once and frozen here so the test needs
  # no hashing library: the shape a stored digest takes.
  ONCE_VALID_DIGEST = "$2a$04$vAioTZeJ8lxIh91DbmthMux4mjFypC7.pMg4MiEBAkO59Xaqkp72S".freeze

  # The column is ignored by the model, so the digest is written the only way a
  # row like production's could be: under the model.
  def plant_digest(user)
    User.connection.update(
      User.sanitize_sql_array(["UPDATE users SET password_digest = ? WHERE id = ?", ONCE_VALID_DIGEST, user.id])
    )
  end

  def stored_digest(user)
    User.connection.select_value(User.sanitize_sql_array(["SELECT password_digest FROM users WHERE id = ?", user.id]))
  end

  def login_route_drawn?
    Rails.application.routes.recognize_path("/login", method: :post)
    true
  rescue ActionController::RoutingError
    false
  end

  def post_password(user)
    post "/login", params: { email: user.email, password: ONCE_VALID }
  end

  def assert_refused
    if login_route_drawn?
      assert_redirected_to login_path, "a drawn POST /login must bounce at the wall"
    else
      assert_response :not_found
    end
  end

  # --- the model --------------------------------------------------------------

  test "[unit] User no longer authenticates a password" do
    user = users(:alex)

    refute user.respond_to?(:authenticate), "User#authenticate is the method sessions#create calls"
    refute User.method_defined?(:password=), "no password can be set, so none can be stored"
    refute Studio.user_supports_password?, "the engine must see a passwordless User"
    refute Studio.password_login_available?
  end

  test "[unit] User does not read the password_digest column" do
    assert_includes User.ignored_columns, "password_digest"
    refute_includes User.column_names, "password_digest"
  end

  # --- the door ---------------------------------------------------------------

  test "[integration] POST /login with a once-valid password cannot sign a visitor in as an admin" do
    admin = users(:alex)
    plant_digest(admin)

    post_password(admin)

    assert_refused
    assert_nil session[Studio.session_key], "a password must not start a session"
    get tasks_path, as: :json
    assert_response :unauthorized
  end

  test "[integration] POST /login with a once-valid password cannot sign a visitor in as a viewer" do
    viewer = users(:viewer)
    plant_digest(viewer)

    post_password(viewer)

    assert_refused
    assert_nil session[Studio.session_key]
  end

  test "[integration] a signed-in viewer cannot switch to an admin with the admin's password" do
    admin = users(:alex)
    viewer = users(:viewer)
    plant_digest(admin)
    log_in_as viewer

    post_password(admin)

    if login_route_drawn?
      assert_redirected_to root_path, "a drawn POST /login is admin-only behind the wall"
    else
      assert_response :not_found
    end
    assert_equal viewer.id, session[Studio.session_key], "the session still belongs to the viewer"
    get tasks_path, as: :json
    assert_response :forbidden
  end
end

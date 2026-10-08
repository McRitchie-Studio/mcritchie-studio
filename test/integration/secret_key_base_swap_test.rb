require "test_helper"

# [integration] A signed-in session survives a simulated SECRET_KEY_BASE swap.
#
# The swap is simulated where Rails reads it on every request: the app's
# env_config, whose key generator, secret_key_base and cookie rotations every
# request's cookie jar is built from. The test signs in under the app's real key,
# swaps to a fresh key with the old one registered through SecretKeyBaseRotation
# (the same call the initializer makes for OLD_SECRET_KEY_BASE), and asks for an
# admin page.
class SecretKeyBaseSwapTest < ActionDispatch::IntegrationTest
  KEYS = %w[action_dispatch.key_generator action_dispatch.secret_key_base action_dispatch.cookies_rotations].freeze

  setup do
    @old_key = Rails.application.secret_key_base
    @new_key = SecureRandom.hex(64)
    @saved = Rails.application.env_config.slice(*KEYS)
  end

  teardown do
    Rails.application.env_config.merge!(@saved)
    restore_key_generator_memo
  end

  test "a signed-in session survives the swap, and the cookie is re-written under the new key" do
    log_in_as(users(:alex))
    get deployments_path
    assert_response :success

    swap_to(@new_key, rotate_from: @old_key)
    get deployments_path
    assert_response :success, "the old-key session should still be authenticated under rotation"

    # The response above re-wrote the session under the new key, so it now reads
    # with the rotation gone: the state step 3 leaves behind.
    swap_to(@new_key)
    get deployments_path
    assert_response :success, "the rotated session should have been re-written under the new key"
  end

  # The 2026-10-07 defect, reproduced on a real session cookie. In production the
  # initializer registers the rotation during config/initializers, when the
  # KeyGenerator class default is still SHA1 and nothing has derived the old key
  # yet. Here the same conditions are rebuilt: the app's memoized generator for the
  # old key is set aside and apply! runs under the SHA1 default. Red before the fix
  # (the rotation came out SHA1 and the visitor was signed out); green after.
  test "the session survives when the rotation is registered at boot, under the SHA1 default" do
    log_in_as(users(:alex))
    get deployments_path
    assert_response :success

    swap_to(@new_key, rotate_from: @old_key, at_boot: true)
    get deployments_path
    assert_response :success, "a rotation registered at boot should read the real SHA256 session cookie"
  end

  # The control: the same swap with no rotation signs the visitor out. Without it
  # the test above could pass because the swap never reached the cookie jar.
  test "control: the swap without rotation signs the session out" do
    log_in_as(users(:alex))
    get deployments_path
    assert_response :success

    swap_to(@new_key)
    get deployments_path
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  # The tamper control: the survival test above, with one character of the
  # old-key session cookie changed before the first request after the swap.
  test "a tampered session cookie fails after the swap" do
    log_in_as(users(:alex))
    get deployments_path
    assert_response :success

    swap_to(@new_key, rotate_from: @old_key)
    name = Rails.application.config.session_options.fetch(:key)
    sealed = cookies[name]
    assert sealed.present?, "the session cookie should be in the jar before it is tampered"
    cookies[name] = flip_first_character(sealed)
    assert_not_equal sealed, cookies[name], "the tampered cookie should be the one sent"

    get deployments_path
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  private

  def flip_first_character(value)
    (value[0] == "A" ? "B" : "A") + value[1..]
  end

  def swap_to(secret_key_base, rotate_from: nil, at_boot: false)
    rotations = ActiveSupport::Messages::RotationConfiguration.new
    if rotate_from && at_boot
      as_at_boot(rotate_from) { SecretKeyBaseRotation.apply!(rotations, old_secret_key_base: rotate_from) }
    elsif rotate_from
      SecretKeyBaseRotation.apply!(rotations, old_secret_key_base: rotate_from)
    end
    Rails.application.env_config.merge!(
      "action_dispatch.key_generator" => Rails.application.key_generator(secret_key_base),
      "action_dispatch.secret_key_base" => secret_key_base,
      "action_dispatch.cookies_rotations" => rotations
    )
  end

  # Run the block as the initializer runs: the KeyGenerator class default back at
  # SHA1, and no memoized generator for `secret_key_base` in
  # Rails.application.key_generator yet. The memo entry is set aside, not lost: the
  # teardown puts it back so later tests see the app exactly as booted.
  def as_at_boot(secret_key_base)
    memo = Rails.application.instance_variable_get(:@key_generators)
    @set_aside = [memo, secret_key_base, memo.delete(secret_key_base)]
    saved_digest = ActiveSupport::KeyGenerator.hash_digest_class
    ActiveSupport::KeyGenerator.hash_digest_class = OpenSSL::Digest::SHA1
    yield
  ensure
    ActiveSupport::KeyGenerator.hash_digest_class = saved_digest if saved_digest
  end

  def restore_key_generator_memo
    return unless @set_aside

    memo, key, generator = @set_aside
    generator ? memo[key] = generator : memo.delete(key)
  end
end

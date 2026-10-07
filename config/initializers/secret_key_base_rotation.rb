# SECRET_KEY_BASE ROTATION — keep signed and encrypted cookies readable across a
# key swap (task hub-rotates-secret-key-base).
#
# Every cookie the hub sets is signed or encrypted with a key derived from
# secret_key_base, and the session cookie is one of them. Swapping the key alone
# would sign every visitor out. With OLD_SECRET_KEY_BASE set to the previous key,
# Rails reads a cookie under the old key when the new one fails, then re-writes it
# under the new key on that same response (the cookie jars' `force_reserialize`).
# A visitor who comes back during the window is migrated in one request.
#
# UNSET IS A NO-OP. With OLD_SECRET_KEY_BASE blank the app boots exactly as it did
# before this file existed: no rotation is registered.
#
# WHAT THIS DOES NOT ROTATE, ON PURPOSE. Only cookies. Rails.application.message_verifiers
# (board API tokens, the contact-form proof, Active Storage signed blob ids) stay on
# the new key alone. The old key is the LEAKED one, and a verifier rotation would let
# anyone holding it keep minting board tokens or signed blob ids (blob ids are
# sequential, so that is a read of any file) for the whole window. What breaks at the
# swap instead is listed in docs/agents/modules/secret-key-base-rotation.md.
#
# THE WINDOW IS THE EXPOSURE. While OLD_SECRET_KEY_BASE is set, a holder of the old
# key can still forge a session cookie. Close the window (unset the var; no code
# change is needed, see above) as soon as active sessions have been migrated.
module SecretKeyBaseRotation
  ENV_VAR = "OLD_SECRET_KEY_BASE"

  module_function

  # The old key, or nil when the var is unset or blank.
  def old_secret_key_base(env = ENV)
    env[ENV_VAR].to_s.strip.presence
  end

  # Register the old key's signed and encrypted cookie secrets on `rotations` (an
  # ActiveSupport::Messages::RotationConfiguration). Returns true when it registered,
  # false when there was no old key. The derivation is Rails' own:
  # Rails.application.key_generator(key) is the same PBKDF2 (1000 iterations, the
  # app's hash digest class) that request.key_generator uses for the live key, and
  # the salts and cipher are read from the app config rather than restated here.
  # Rotation options inherit the primary jar's cipher, digest and serializer.
  def apply!(rotations, old_secret_key_base:, config: Rails.application.config.action_dispatch)
    return false if old_secret_key_base.blank?

    key_generator = Rails.application.key_generator(old_secret_key_base)
    cipher = config.encrypted_cookie_cipher || "aes-256-gcm"
    key_len = ActiveSupport::MessageEncryptor.key_len(cipher)

    rotations.rotate :encrypted, key_generator.generate_key(config.authenticated_encrypted_cookie_salt, key_len)
    rotations.rotate :signed, key_generator.generate_key(config.signed_cookie_salt)
    true
  end
end

SecretKeyBaseRotation.apply!(
  Rails.application.config.action_dispatch.cookies_rotations,
  old_secret_key_base: SecretKeyBaseRotation.old_secret_key_base
)

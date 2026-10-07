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
# swap instead is listed in docs/agents/system/secrets-rotation.md ("Hub SECRET_KEY_BASE").
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

  # The post-swap proof `bin/rails secret_key_base:verify_rotation` runs on the
  # dyno: it writes a signed and an encrypted cookie under OLD_SECRET_KEY_BASE and
  # reads both through a cookie jar built from the app's LIVE key and rotations.
  # Returns [ok, lines]. The lines carry 16-character SHA-256 digests only, never
  # a key. An unset var is a failure, not a pass: there is nothing to prove.
  def verify(app: Rails.application, env: ENV, rotations: app.config.action_dispatch.cookies_rotations)
    require "digest"
    require "action_dispatch/testing/test_request"

    digest = ->(v) { v.to_s.empty? ? "EMPTY" : Digest::SHA256.hexdigest(v.to_s)[0, 16] }
    old = old_secret_key_base(env)
    lines = ["runtime=#{digest.(app.secret_key_base)} old=#{digest.(old)} " \
             "rotations signed=#{rotations.signed.size} encrypted=#{rotations.encrypted.size}"]
    return [false, lines << "FAIL: #{ENV_VAR} is unset"] if old.nil?

    jar = lambda do |key_generator, rots, cookies = {}|
      request = ActionDispatch::TestRequest.create(app.env_config.merge(
        "action_dispatch.key_generator" => key_generator,
        "action_dispatch.cookies_rotations" => rots,
        "HTTP_HOST" => "localhost"
      ))
      request.cookie_jar.update(cookies)
      request.cookie_jar
    end

    writer = jar.(app.key_generator(old), ActiveSupport::Messages::RotationConfiguration.new)
    writer.encrypted[:probe] = "encrypted-ok"
    encrypted = writer[:probe]
    writer.signed[:probe] = "signed-ok"
    signed = writer[:probe]

    ok = jar.(app.key_generator, rotations, "probe" => encrypted).encrypted[:probe] == "encrypted-ok" &&
         jar.(app.key_generator, rotations, "probe" => signed).signed[:probe] == "signed-ok"
    [ok, lines << (ok ? "PASS: old-key signed and encrypted cookies read under the live key" :
                        "FAIL: an old-key cookie did not read under the live key")]
  end
end

SecretKeyBaseRotation.apply!(
  Rails.application.config.action_dispatch.cookies_rotations,
  old_secret_key_base: SecretKeyBaseRotation.old_secret_key_base
)

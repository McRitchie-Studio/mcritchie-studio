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

  # The digest every cookie secret is derived with. Explicit, never the class
  # default: this file runs during config/initializers, BEFORE Active Support's
  # after_initialize sets ActiveSupport::KeyGenerator.hash_digest_class to SHA256,
  # so a generator built here without a digest bakes in SHA1 for good. That is how
  # the 2026-10-07 swap signed every visitor out (task
  # rotation-derives-old-key-sha256). It must equal the app's
  # config.active_support.key_generator_hash_digest_class (load_defaults 7.0+); a
  # test pins the two together.
  HASH_DIGEST_CLASS = OpenSSL::Digest::SHA256

  # The old key's PBKDF2 generator: Rails' own derivation for a live key (1000
  # iterations) with the digest stated, built fresh rather than through
  # Rails.application.key_generator(key), whose per-key memo would cache it.
  def key_generator(secret_key_base)
    ActiveSupport::KeyGenerator.new(secret_key_base, iterations: 1000, hash_digest_class: HASH_DIGEST_CLASS)
  end

  # Register the old key's signed and encrypted cookie secrets on `rotations` (an
  # ActiveSupport::Messages::RotationConfiguration). Returns true when it registered,
  # false when there was no old key. The secrets come from `key_generator` above:
  # PBKDF2 with SHA256 stated explicitly, because the class default is still SHA1
  # when this runs at boot. The salts and cipher are read from the app config rather
  # than restated here. Rotation options inherit the primary jar's cipher, digest
  # and serializer.
  def apply!(rotations, old_secret_key_base:, config: Rails.application.config.action_dispatch)
    return false if old_secret_key_base.blank?

    key_generator = key_generator(old_secret_key_base)
    cipher = config.encrypted_cookie_cipher || "aes-256-gcm"
    key_len = ActiveSupport::MessageEncryptor.key_len(cipher)

    rotations.rotate :encrypted, key_generator.generate_key(config.authenticated_encrypted_cookie_salt, key_len)
    rotations.rotate :signed, key_generator.generate_key(config.signed_cookie_salt)
    true
  end

  # The post-swap proof `bin/rails secret_key_base:verify_rotation` runs on the
  # dyno. It seals a signed and an encrypted probe the way the live request path
  # sealed cookies while OLD_SECRET_KEY_BASE was the app's key, and reads both
  # through a jar built from the app's LIVE request key generator and rotations.
  #
  # The probe's generator is derived independently of this module and of
  # Rails.application.key_generator(old): from the app's configured
  # key_generator_hash_digest_class, as a request on the old key derived it. The
  # 2026-10-07 run wrote and read through that memo, which held the SHA1 copy the
  # initializer had cached, and passed while no real cookie read. As a control it
  # also seals a SHA1 probe, which must NOT read.
  #
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
    # Equal keys read the probe with no rotation at all: a PASS would prove nothing.
    return [false, lines << "FAIL: #{ENV_VAR} equals the live key"] if old == app.secret_key_base

    jar = lambda do |key_generator, rots, cookies = {}|
      request = ActionDispatch::TestRequest.create(app.env_config.merge(
        "action_dispatch.key_generator" => key_generator,
        "action_dispatch.cookies_rotations" => rots,
        "HTTP_HOST" => "localhost"
      ))
      request.cookie_jar.update(cookies)
      request.cookie_jar
    end

    seal = lambda do |key_generator|
      writer = jar.(key_generator, ActiveSupport::Messages::RotationConfiguration.new)
      writer.encrypted[:probe] = "encrypted-ok"
      encrypted = writer[:probe]
      writer.signed[:probe] = "signed-ok"
      [encrypted, writer[:probe]]
    end

    reads = lambda do |(encrypted, signed)|
      live = app.env_config["action_dispatch.key_generator"]
      [jar.(live, rotations, "probe" => encrypted).encrypted[:probe] == "encrypted-ok",
       jar.(live, rotations, "probe" => signed).signed[:probe] == "signed-ok"]
    end

    request_digest = app.config.active_support.key_generator_hash_digest_class || ActiveSupport::KeyGenerator.hash_digest_class
    request_path = ActiveSupport::KeyGenerator.new(old, iterations: 1000, hash_digest_class: request_digest)
    sha1 = ActiveSupport::KeyGenerator.new(old, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA1)

    real = reads.(seal.(request_path))
    control = reads.(seal.(sha1))
    lines << "probe digest=#{request_digest.name.demodulize} encrypted=#{real[0]} signed=#{real[1]}; " \
             "SHA1 control encrypted=#{control[0]} signed=#{control[1]}"

    ok = real.all? && control.none?
    [ok, lines << (ok ? "PASS: old-key signed and encrypted cookies read under the live key; SHA1 control did not" :
                        "FAIL: an old-key cookie did not read under the live key, or the SHA1 control did")]
  end
end

SecretKeyBaseRotation.apply!(
  Rails.application.config.action_dispatch.cookies_rotations,
  old_secret_key_base: SecretKeyBaseRotation.old_secret_key_base
)

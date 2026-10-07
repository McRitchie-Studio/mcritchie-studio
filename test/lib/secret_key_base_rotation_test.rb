require "test_helper"

# Helpers shared by the rotation tests below.
#
# THE BOOT-ORDER TRAP (task rotation-derives-old-key-sha256). The initializer runs
# during config/initializers, BEFORE Active Support's after_initialize sets
# ActiveSupport::KeyGenerator.hash_digest_class to SHA256. A KeyGenerator built then
# without an explicit digest bakes in the class default, SHA1, and keeps it. A test
# that calls apply! after boot never sees that, which is how the first suite passed
# while every pre-swap session in production signed out. `during_initializers`
# puts the class default back to SHA1 for the length of a block, so apply! runs
# under the same conditions it meets at boot.
module SecretKeyBaseRotationTestHelpers
  private

  def during_initializers
    saved = ActiveSupport::KeyGenerator.hash_digest_class
    ActiveSupport::KeyGenerator.hash_digest_class = OpenSSL::Digest::SHA1
    yield
  ensure
    ActiveSupport::KeyGenerator.hash_digest_class = saved
  end

  # A fresh key per test, so Rails.application.key_generator's per-key memo (the
  # cache the defect poisoned) never carries one test's derivation into another.
  def fresh_key = SecureRandom.hex(64)

  # The generator a live request on `secret_key_base` seals its cookies with: the
  # PBKDF2 Rails builds after boot (1000 iterations, the app's configured key
  # generator digest). Built here from the config, NOT through
  # Rails.application.key_generator, whose memo can hold a boot-time SHA1 copy.
  def live_key_generator(secret_key_base)
    ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(
        secret_key_base, iterations: 1000,
        hash_digest_class: Rails.application.config.active_support.key_generator_hash_digest_class
      )
    )
  end

  def sha1_key_generator(secret_key_base)
    ActiveSupport::KeyGenerator.new(secret_key_base, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA1)
  end

  def jar_for(key_generator, rotations, cookies = {})
    env = Rails.application.env_config.merge(
      "action_dispatch.key_generator" => key_generator,
      "action_dispatch.cookies_rotations" => rotations,
      "HTTP_HOST" => "www.example.com"
    )
    request = ActionDispatch::TestRequest.create(env)
    request.cookie_jar.update(cookies)
    request.cookie_jar
  end

  # The raw (signed or encrypted) cookie string a jar on `key_generator` writes.
  def write_cookie(key_generator)
    jar = jar_for(key_generator, ActiveSupport::Messages::RotationConfiguration.new)
    yield jar
    jar[:probe]
  end

  def rotations_from(old_secret_key_base)
    ActiveSupport::Messages::RotationConfiguration.new.tap do |rotations|
      SecretKeyBaseRotation.apply!(rotations, old_secret_key_base: old_secret_key_base)
    end
  end

  # Rotations registered the way the defective initializer registered them: the
  # old key's secrets derived with SHA1.
  def sha1_rotations_from(old_secret_key_base)
    config = Rails.application.config.action_dispatch
    generator = sha1_key_generator(old_secret_key_base)
    key_len = ActiveSupport::MessageEncryptor.key_len(config.encrypted_cookie_cipher || "aes-256-gcm")
    ActiveSupport::Messages::RotationConfiguration.new.tap do |rotations|
      rotations.rotate :encrypted, generator.generate_key(config.authenticated_encrypted_cookie_salt, key_len)
      rotations.rotate :signed, generator.generate_key(config.signed_cookie_salt)
    end
  end

  def read_jar(secret_key_base, raw, rotations: ActiveSupport::Messages::RotationConfiguration.new)
    jar_for(live_key_generator(secret_key_base), rotations, "probe" => raw)
  end
end

# [unit] SecretKeyBaseRotation (config/initializers/secret_key_base_rotation.rb):
# a cookie signed or encrypted under the OLD secret_key_base reads under the new
# key once the rotation is registered, and an unset OLD_SECRET_KEY_BASE registers
# nothing.
#
# Each jar is a real ActionDispatch cookie jar built from the app's own env_config,
# with only the key generator and the rotations swapped, so the salts, cipher,
# digest and serializer are the ones production uses.
class SecretKeyBaseRotationTest < ActiveSupport::TestCase
  include SecretKeyBaseRotationTestHelpers

  NEW_KEY = "b" * 128

  # The live request path, unmodified: the jar the app's own env_config builds
  # (its real key generator, its real key) seals the cookie, and the app's key then
  # becomes the OLD one.
  test "a cookie the live request jar sealed reads under the new key with rotation" do
    live = Rails.application.env_config["action_dispatch.key_generator"]
    raw = write_cookie(live) { |jar| jar.encrypted[:probe] = { value: { "user_id" => 42 } } }

    rotations = rotations_from(Rails.application.secret_key_base)

    assert_equal({ "user_id" => 42 }, read_jar(NEW_KEY, raw, rotations: rotations).encrypted[:probe])
  end

  # The regression. apply! runs where the initializer runs it, while the class
  # default is still SHA1, and must still derive the SHA256 secrets a live cookie
  # was sealed with. Red before the fix: Rails.application.key_generator(old)
  # handed back a SHA1 generator and neither cookie read.
  test "apply! during initializers still reads a real SHA256 cookie from the old key" do
    old = fresh_key
    encrypted = write_cookie(live_key_generator(old)) { |jar| jar.encrypted[:probe] = "encrypted-under-old" }
    signed = write_cookie(live_key_generator(old)) { |jar| jar.signed[:probe] = "signed-under-old" }

    rotations = during_initializers { rotations_from(old) }

    assert_equal "encrypted-under-old", read_jar(NEW_KEY, encrypted, rotations: rotations).encrypted[:probe]
    assert_equal "signed-under-old", read_jar(NEW_KEY, signed, rotations: rotations).signed[:probe]
  end

  # The SHA1 control. A cookie sealed with a SHA1 derivation of the old key does
  # NOT read: the rotation is SHA256 only, so the test above cannot pass by
  # accepting either digest.
  test "control: a SHA1-derived old-key cookie does not read under rotation" do
    old = fresh_key
    encrypted = write_cookie(sha1_key_generator(old)) { |jar| jar.encrypted[:probe] = "sha1-encrypted" }
    signed = write_cookie(sha1_key_generator(old)) { |jar| jar.signed[:probe] = "sha1-signed" }

    rotations = during_initializers { rotations_from(old) }

    assert_nil read_jar(NEW_KEY, encrypted, rotations: rotations).encrypted[:probe]
    assert_nil read_jar(NEW_KEY, signed, rotations: rotations).signed[:probe]
  end

  # Pin the agreement the fix relies on: the digest the rotation derives with is the
  # one the app is configured to seal cookies with.
  test "the rotation derives with the app's configured key generator digest" do
    assert_equal Rails.application.config.active_support.key_generator_hash_digest_class,
                 SecretKeyBaseRotation::HASH_DIGEST_CLASS
    assert_equal OpenSSL::Digest::SHA256, SecretKeyBaseRotation::HASH_DIGEST_CLASS
  end

  test "a cookie signed with the old key reads under rotation" do
    old = fresh_key
    raw = write_cookie(live_key_generator(old)) { |jar| jar.signed[:probe] = "signed-under-old" }

    assert_equal "signed-under-old", read_jar(NEW_KEY, raw, rotations: rotations_from(old)).signed[:probe]
  end

  # The control. The same old-key cookies against the new key with NO rotation
  # read as nil. Without this the tests above could pass because the jar ignored
  # the key altogether.
  test "control: without the rotation an old-key cookie does not read" do
    old = fresh_key
    signed = write_cookie(live_key_generator(old)) { |jar| jar.signed[:probe] = "signed-under-old" }
    encrypted = write_cookie(live_key_generator(old)) { |jar| jar.encrypted[:probe] = "encrypted-under-old" }

    assert_nil read_jar(NEW_KEY, signed).signed[:probe]
    assert_nil read_jar(NEW_KEY, encrypted).encrypted[:probe]
  end

  test "a cookie from an unrelated key still does not read under rotation" do
    raw = write_cookie(live_key_generator(fresh_key)) { |jar| jar.encrypted[:probe] = "forged" }

    assert_nil read_jar(NEW_KEY, raw, rotations: rotations_from(fresh_key)).encrypted[:probe]
  end

  test "unset or blank OLD_SECRET_KEY_BASE registers no rotation" do
    old = fresh_key
    assert_nil SecretKeyBaseRotation.old_secret_key_base({})
    assert_nil SecretKeyBaseRotation.old_secret_key_base("OLD_SECRET_KEY_BASE" => "  ")
    assert_equal old, SecretKeyBaseRotation.old_secret_key_base("OLD_SECRET_KEY_BASE" => old)

    rotations = ActiveSupport::Messages::RotationConfiguration.new
    assert_equal false, SecretKeyBaseRotation.apply!(rotations, old_secret_key_base: nil)
    assert_empty rotations.signed
    assert_empty rotations.encrypted
  end

  # The boot-time registration matches the environment: none when the var is
  # unset (the no-op promise), one of each when it is set.
  test "the app booted with exactly the rotations its environment asks for" do
    expected = SecretKeyBaseRotation.old_secret_key_base ? 1 : 0
    rotations = Rails.application.config.action_dispatch.cookies_rotations

    assert_equal expected, rotations.signed.size
    assert_equal expected, rotations.encrypted.size
  end
end

# [unit] SecretKeyBaseRotation.verify, the step 2 on-dyno proof
# (bin/rails secret_key_base:verify_rotation): PASS only when the old key is set AND
# registered with the derivation a real cookie used, and its output carries
# digests, never a key.
class SecretKeyBaseRotationVerifyTest < ActiveSupport::TestCase
  include SecretKeyBaseRotationTestHelpers

  test "passes when the old key is set and registered" do
    old = fresh_key
    rotations = during_initializers { rotations_from(old) }

    ok, lines = SecretKeyBaseRotation.verify(env: { "OLD_SECRET_KEY_BASE" => old }, rotations: rotations)

    assert ok, lines.join("\n")
    assert_match(/PASS/, lines.last)
    refute(lines.any? { |l| l.include?(old) || l.include?(Rails.application.secret_key_base) })
  end

  # The false PASS of 2026-10-07, reproduced. The initializer had memoized a SHA1
  # generator for the old key in Rails.application.key_generator(old) and
  # registered SHA1 rotations; verify then wrote its probe through that same memo
  # and read it back, proving nothing. Sealing through the live request path's
  # derivation instead, verify must FAIL on SHA1 rotations however the memo looks.
  test "control: fails when the registered rotation is SHA1-derived, even with a poisoned memo" do
    old = fresh_key
    during_initializers { Rails.application.key_generator(old) }

    ok, lines = SecretKeyBaseRotation.verify(env: { "OLD_SECRET_KEY_BASE" => old }, rotations: sha1_rotations_from(old))

    refute ok, lines.join("\n")
    assert_match(/FAIL/, lines.last)
  end

  test "control: fails when the old key is set but no rotation is registered" do
    ok, lines = SecretKeyBaseRotation.verify(env: { "OLD_SECRET_KEY_BASE" => fresh_key },
                                             rotations: ActiveSupport::Messages::RotationConfiguration.new)

    refute ok
    assert_match(/FAIL/, lines.last)
  end

  test "fails when OLD_SECRET_KEY_BASE is unset" do
    ok, lines = SecretKeyBaseRotation.verify(env: {})

    refute ok
    assert_match(/unset/, lines.last)
  end
end

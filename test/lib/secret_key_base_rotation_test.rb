require "test_helper"

# [unit] SecretKeyBaseRotation (config/initializers/secret_key_base_rotation.rb):
# a cookie signed or encrypted under the OLD secret_key_base reads under the new
# key once the rotation is registered, and an unset OLD_SECRET_KEY_BASE registers
# nothing.
#
# Each jar is a real ActionDispatch cookie jar built from the app's own env_config,
# with only the key generator and the rotations swapped, so the salts, cipher,
# digest and serializer are the ones production uses.
class SecretKeyBaseRotationTest < ActiveSupport::TestCase
  OLD_KEY = "a" * 128
  NEW_KEY = "b" * 128

  test "a cookie signed with the old key reads under rotation" do
    raw = write_cookie(OLD_KEY) { |jar| jar.signed[:probe] = "signed-under-old" }

    assert_equal "signed-under-old", read_jar(NEW_KEY, raw, rotate_from: OLD_KEY).signed[:probe]
  end

  test "a cookie encrypted with the old key reads under rotation" do
    raw = write_cookie(OLD_KEY) { |jar| jar.encrypted[:probe] = { value: { "user_id" => 42 } } }

    assert_equal({ "user_id" => 42 }, read_jar(NEW_KEY, raw, rotate_from: OLD_KEY).encrypted[:probe])
  end

  # The control. The same old-key cookies against the new key with NO rotation
  # read as nil. Without this the two tests above could pass because the jar
  # ignored the key altogether.
  test "control: without the rotation an old-key cookie does not read" do
    signed = write_cookie(OLD_KEY) { |jar| jar.signed[:probe] = "signed-under-old" }
    encrypted = write_cookie(OLD_KEY) { |jar| jar.encrypted[:probe] = "encrypted-under-old" }

    assert_nil read_jar(NEW_KEY, signed).signed[:probe]
    assert_nil read_jar(NEW_KEY, encrypted).encrypted[:probe]
  end

  test "a cookie from an unrelated key still does not read under rotation" do
    raw = write_cookie("c" * 128) { |jar| jar.encrypted[:probe] = "forged" }

    assert_nil read_jar(NEW_KEY, raw, rotate_from: OLD_KEY).encrypted[:probe]
  end

  test "unset or blank OLD_SECRET_KEY_BASE registers no rotation" do
    assert_nil SecretKeyBaseRotation.old_secret_key_base({})
    assert_nil SecretKeyBaseRotation.old_secret_key_base("OLD_SECRET_KEY_BASE" => "  ")
    assert_equal OLD_KEY, SecretKeyBaseRotation.old_secret_key_base("OLD_SECRET_KEY_BASE" => OLD_KEY)

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

  private

  def jar_for(secret_key_base, rotations, cookies = {})
    env = Rails.application.env_config.merge(
      "action_dispatch.key_generator" => Rails.application.key_generator(secret_key_base),
      "action_dispatch.cookies_rotations" => rotations,
      "HTTP_HOST" => "www.example.com"
    )
    request = ActionDispatch::TestRequest.create(env)
    request.cookie_jar.update(cookies)
    request.cookie_jar
  end

  # The raw (signed or encrypted) cookie string a jar on `secret_key_base` writes.
  def write_cookie(secret_key_base)
    jar = jar_for(secret_key_base, ActiveSupport::Messages::RotationConfiguration.new)
    yield jar
    jar[:probe]
  end

  def read_jar(secret_key_base, raw, rotate_from: nil)
    rotations = ActiveSupport::Messages::RotationConfiguration.new
    SecretKeyBaseRotation.apply!(rotations, old_secret_key_base: rotate_from) if rotate_from
    jar_for(secret_key_base, rotations, "probe" => raw)
  end
end

# [unit] SecretKeyBaseRotation.verify, the step 2 on-dyno proof
# (bin/rails secret_key_base:verify_rotation): PASS only when the old key is set AND
# registered, and its output carries digests, never a key.
class SecretKeyBaseRotationVerifyTest < ActiveSupport::TestCase
  OLD_KEY = "d" * 128

  test "passes when the old key is set and registered" do
    rotations = ActiveSupport::Messages::RotationConfiguration.new
    SecretKeyBaseRotation.apply!(rotations, old_secret_key_base: OLD_KEY)

    ok, lines = SecretKeyBaseRotation.verify(env: { "OLD_SECRET_KEY_BASE" => OLD_KEY }, rotations: rotations)

    assert ok, lines.join("\n")
    assert_match(/PASS/, lines.last)
    refute(lines.any? { |l| l.include?(OLD_KEY) || l.include?(Rails.application.secret_key_base) })
  end

  test "control: fails when the old key is set but no rotation is registered" do
    ok, lines = SecretKeyBaseRotation.verify(env: { "OLD_SECRET_KEY_BASE" => OLD_KEY },
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

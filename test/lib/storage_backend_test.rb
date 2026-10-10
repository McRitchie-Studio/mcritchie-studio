require "test_helper"

# [unit] The hub's object storage is Cloudflare R2 and nothing else
# (config/initializers/00_storage_backend.rb). AWS was retired on 2026-10-10, so
# this file holds the BOOT MATRIX: what each value of ACTIVE_STORAGE_BACKEND and
# STUDIO_S3_BACKEND resolves to, and what a missing R2_* variable does in a
# strict environment (production, QA) against a lenient one (test, CI, a keyless
# desk). A bad storage config once passed Heroku's release phase and then
# crash-looped web and worker; test/integration/storage_boot_matrix_test.rb
# boots real child processes for the same matrix.
#
# Asserted on the service objects Active Storage builds, as
# storage_service_config_test.rb does. No network calls; credentials are sentinels.
class StorageBackendTest < ActiveSupport::TestCase
  R2_ENDPOINT = "https://sentinel-account.r2.cloudflarestorage.com".freeze
  R2_PUBLIC_URL = "https://assets.example.com".freeze
  R2_ENV = {
    "R2_ENDPOINT" => R2_ENDPOINT,
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "R2_PUBLIC_URL" => R2_PUBLIC_URL
  }.freeze
  SWITCHES = %w[ACTIVE_STORAGE_BACKEND STUDIO_S3_BACKEND].freeze
  UNCONFIGURED_ENDPOINT = "https://r2-not-configured.invalid".freeze

  # --- the stage readers --------------------------------------------------------

  test "unset and blank mean R2, never S3" do
    assert_equal "r2", StorageBackend.active_storage_stage({})
    assert_equal "r2", StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => "" })
    assert_equal "r2", StorageBackend.studio_s3_stage({})
    assert_equal "r2", StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => "  " })
  end

  test "the live value r2 stays valid for both switches" do
    assert_equal "r2", StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => "r2" })
    assert_equal "r2", StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => "r2" })
  end

  %w[s3 mirror_to_r2 mirror_to_s3].each do |retired|
    test "the retired stage #{retired} raises for both switches, naming the variable and the remedy" do
      SWITCHES.each do |name|
        reader = name == "ACTIVE_STORAGE_BACKEND" ? :active_storage_stage : :studio_s3_stage
        error = assert_raises(ArgumentError) { StorageBackend.public_send(reader, { name => retired }) }
        assert_includes error.message, "#{name}=#{retired.inspect}"
        assert_match(/retired/, error.message)
        assert_match(/set it to r2/, error.message)
      end
    end
  end

  test "a typo raises instead of resolving anything" do
    error = assert_raises(ArgumentError) { StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => "R2" }) }
    assert_includes error.message, 'ACTIVE_STORAGE_BACKEND="R2"'
    assert_raises(ArgumentError) { StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => "cloudflare" }) }
  end

  # --- validate!: the whole boot check, strict and lenient -------------------------

  test "strict boot passes with every R2 variable, switches set or unset" do
    assert StorageBackend.validate!(R2_ENV, strict: true)
    assert StorageBackend.validate!(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => "r2", "STUDIO_S3_BACKEND" => "r2"), strict: true)
  end

  R2_ENV.each_key do |name|
    test "strict boot raises naming #{name} when it is missing" do
      error = assert_raises(ArgumentError) { StorageBackend.validate!(R2_ENV.except(name), strict: true) }
      assert_match(/\A#{name} must be set/, error.message)
    end

    test "strict boot raises naming #{name} when it is blank" do
      error = assert_raises(ArgumentError) { StorageBackend.validate!(R2_ENV.merge(name => "  "), strict: true) }
      assert_match(/\A#{name} must be set/, error.message)
    end
  end

  test "lenient boot passes with no R2 variable at all" do
    assert StorageBackend.validate!({}, strict: false)
  end

  test "a retired stage fails the boot check in a lenient environment too" do
    SWITCHES.each do |name|
      assert_raises(ArgumentError) { StorageBackend.validate!(R2_ENV.merge(name => "s3"), strict: false) }
      assert_raises(ArgumentError) { StorageBackend.validate!(R2_ENV.merge(name => "s3"), strict: true) }
    end
  end

  test "strictness follows Rails.env.production?, which covers QA" do
    refute StorageBackend.strict?, "the test environment must be lenient"
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) { assert StorageBackend.strict? }
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) { refute StorageBackend.strict? }
  end

  # The placeholder keys a keyless boot configures make "is a key set?" answer
  # yes, so code that must refuse up front asks configured? instead.
  test "configured? is true only with every R2 variable, and an AWS key never counts" do
    assert StorageBackend.configured?(R2_ENV)
    refute StorageBackend.configured?({})
    refute StorageBackend.configured?({ "AWS_ACCESS_KEY_ID" => "AKIA", "AWS_SECRET_ACCESS_KEY" => "x" })
    R2_ENV.each_key do |name|
      refute StorageBackend.configured?(R2_ENV.except(name)), "#{name} missing"
      refute StorageBackend.configured?(R2_ENV.merge(name => " ")), "#{name} blank"
    end
  end

  # --- Studio::S3 settings --------------------------------------------------------

  test "Studio::S3 always gets the R2 endpoint, region, key pair and public URL" do
    expected = {
      s3_endpoint: R2_ENDPOINT,
      s3_region: "auto",
      s3_access_key_id: "r2-sentinel-id",
      s3_secret_access_key: "r2-sentinel-secret",
      s3_public_url: R2_PUBLIC_URL
    }
    assert_equal expected, StorageBackend.studio_s3_settings(R2_ENV, strict: true)
    assert_equal expected, StorageBackend.studio_s3_settings(R2_ENV.merge("STUDIO_S3_BACKEND" => "r2"), strict: true)
    assert_equal expected, StorageBackend.studio_s3_settings(R2_ENV, strict: false)
  end

  # Unset used to mean {} — the engine's AWS defaults with whatever key the SDK's
  # chain found. It must never mean that again, in any environment.
  test "no environment yields empty settings, which would be keyless S3" do
    [ true, false ].each do |strict|
      settings = StorageBackend.studio_s3_settings(R2_ENV, strict: strict)
      assert settings[:s3_endpoint].present?
      refute_match(/amazonaws/, settings[:s3_endpoint])
    end
    assert_equal UNCONFIGURED_ENDPOINT, StorageBackend.studio_s3_settings({}, strict: false)[:s3_endpoint]
  end

  # The hub hands out public Studio::S3 URLs (ImageCache, broadcasts, lineups), and
  # Studio::S3.url raises on R2 without a public base.
  test "strict settings refuse to build without R2_PUBLIC_URL" do
    error = assert_raises(ArgumentError) { StorageBackend.studio_s3_settings(R2_ENV.except("R2_PUBLIC_URL"), strict: true) }
    assert_match(/R2_PUBLIC_URL/, error.message)
  end

  test "Studio::S3 settings refuse a retired stage before reading any key" do
    error = assert_raises(ArgumentError) { StorageBackend.studio_s3_settings({ "STUDIO_S3_BACKEND" => "s3" }, strict: false) }
    assert_match(/STUDIO_S3_BACKEND/, error.message)
  end

  # A reserved .invalid host (RFC 2606) never resolves, and static placeholder
  # keys stop the SDK's default chain from offering a real AWS key to it.
  test "lenient settings without keys are an R2-shaped placeholder that reaches nothing" do
    settings = StorageBackend.studio_s3_settings({}, strict: false)
    assert_equal UNCONFIGURED_ENDPOINT, settings[:s3_endpoint]
    assert_equal "auto", settings[:s3_region]
    assert_equal "r2-not-configured", settings[:s3_access_key_id]
    assert_equal "r2-not-configured", settings[:s3_secret_access_key]
    assert_equal UNCONFIGURED_ENDPOINT, settings[:s3_public_url]
    assert URI(settings[:s3_endpoint]).host.end_with?(".invalid")
  end

  # CI and a desk's test run hold no R2_* variable (they live in .env.development,
  # which the test environment does not load), so this is the lenient boot, live.
  test "the booted test app is on R2 settings, placeholder or real, never AWS defaults" do
    assert Studio.s3_endpoint.present?, "Studio::S3 booted on the engine's AWS defaults"
    refute_match(/amazonaws/, Studio.s3_endpoint)
    assert_equal "auto", Studio.s3_region
    assert Studio.s3_access_key_id.present?
    refute_match(/amazonaws/, Studio::S3.url(key: "probe.png"))
  end

  # --- Active Storage: what each durable service resolves to ----------------------

  def storage_configs(extra = {})
    with_env(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => nil, "QA_ENV" => nil).merge(extra)) do
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    end
  end

  def service(name, extra = {})
    ActiveStorage::Service::Configurator.build(name, storage_configs(extra))
  end

  def endpoint_of(service) = service.client.client.config.endpoint.to_s

  test "storage.yml renders the two disk services and the two R2 services, and nothing else" do
    r2 = { "service" => "StudioTrashS3", "endpoint" => R2_ENDPOINT, "access_key_id" => "r2-sentinel-id",
           "secret_access_key" => "r2-sentinel-secret", "region" => "auto",
           "request_checksum_calculation" => "when_required", "response_checksum_validation" => "when_required" }
    expected = {
      "test" => { "service" => "Disk", "root" => Rails.root.join("tmp/storage").to_s },
      "local" => { "service" => "Disk", "root" => Rails.root.join("storage").to_s },
      "amazon" => r2.merge("bucket" => "mcritchie-studio-production"),
      "amazon_dev" => r2.merge("bucket" => "mcritchie-studio-dev")
    }
    assert_equal expected, storage_configs.deep_stringify_keys, "unset renders R2"
    assert_equal expected, storage_configs("ACTIVE_STORAGE_BACKEND" => "r2").deep_stringify_keys
  end

  test "no rendered service is plain S3, a mirror, or an _s3 leftover" do
    configs = storage_configs.deep_stringify_keys
    assert_empty configs.keys.grep(/_s3\z|_r2\z/)
    assert_equal %w[Disk StudioTrashS3], configs.values.map { |c| c["service"] }.uniq.sort
  end

  %w[s3 mirror_to_r2 mirror_to_s3].each do |retired|
    test "storage.yml refuses to render at the retired stage #{retired}" do
      error = assert_raises(ArgumentError) { storage_configs("ACTIVE_STORAGE_BACKEND" => retired) }
      assert_match(/ACTIVE_STORAGE_BACKEND/, error.message)
    end
  end

  %i[amazon amazon_dev].each do |name|
    bucket = name == :amazon ? "mcritchie-studio-production" : "mcritchie-studio-dev"

    test "#{name}: the engine's trash service on R2, same bucket name, R2 keys" do
      svc = service(name)
      assert_instance_of ActiveStorage::Service::StudioTrashS3Service, svc
      assert_equal R2_ENDPOINT, endpoint_of(svc)
      assert_equal bucket, svc.bucket.name
      assert_equal "auto", svc.client.client.config.region
      assert_equal "r2-sentinel-id", svc.client.client.config.credentials.access_key_id
    end

    # Active Storage sends Content-MD5 and aws-sdk-s3 >= 1.178 adds a CRC32 by
    # default; R2 refuses both at once ("only one non-default checksum").
    test "#{name}: checksums are computed only when required" do
      svc = service(name)
      assert_equal "when_required", svc.client.client.config.request_checksum_calculation
      assert_equal "when_required", svc.client.client.config.response_checksum_validation
    end

    # The test, CI and keyless-desk render: it must parse AND build, and the
    # client it builds must point at the placeholder, not at AWS.
    test "#{name}: with no R2 variable the lenient render still builds, on the placeholder host" do
      keyless = R2_ENV.transform_values { nil }
      svc = service(name, keyless)
      assert_instance_of ActiveStorage::Service::StudioTrashS3Service, svc
      assert_equal UNCONFIGURED_ENDPOINT, endpoint_of(svc)
      assert_equal "r2-not-configured", svc.client.client.config.credentials.access_key_id
      assert_equal bucket, svc.bucket.name
    end
  end

  test "a strict render raises naming the missing variable instead of rendering a placeholder" do
    error = assert_raises(ArgumentError) do
      StorageBackend.active_storage_services({ "amazon" => "b" }, R2_ENV.except("R2_ENDPOINT"), strict: true)
    end
    assert_match(/\AR2_ENDPOINT must be set/, error.message)
  end

  test "QA_ENV picks the dev bucket for amazon" do
    assert_equal "mcritchie-studio-dev", service(:amazon, "QA_ENV" => "true").bucket.name
  end

  # --- remedy text ----------------------------------------------------------------

  test "credential_hint names the R2 keys and never AWS" do
    [ {}, { "STUDIO_S3_BACKEND" => "r2" } ].each do |env|
      assert_match(/R2_ACCESS_KEY_ID/, StorageBackend.credential_hint(env))
      refute_match(/AWS_/, StorageBackend.credential_hint(env))
    end
  end

  test "the headshot rake aborts take their credential text from credential_hint, not a hardcoded AWS list" do
    rake = Rails.root.join("lib/tasks/nfl.rake").read
    assert_equal 2, rake.scan("StorageBackend.credential_hint").size, "upload_headshots and rekey_headshots"
    refute_match(%r{AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION}, rake)
  end

  private

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

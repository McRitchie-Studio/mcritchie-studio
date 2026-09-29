require "test_helper"

# [unit] The two switches that move the hub's storage off AWS S3 onto Cloudflare
# R2 (config/initializers/00_storage_backend.rb): ACTIVE_STORAGE_BACKEND, which
# config/storage.yml reads for BOTH durable services (amazon and amazon_dev), and
# STUDIO_S3_BACKEND, which config/initializers/studio.rb reads.
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
    "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLEONLYTEST",
    "AWS_SECRET_ACCESS_KEY" => "aws-sentinel-secret"
  }.freeze

  # --- the stage readers --------------------------------------------------------

  test "unset and blank read as the S3 stage" do
    assert_equal "s3", StorageBackend.active_storage_stage({})
    assert_equal "s3", StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => "  " })
  end

  test "every documented stage reads back as itself" do
    %w[s3 mirror_to_r2 mirror_to_s3 r2].each do |stage|
      assert_equal stage, StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => stage })
    end
    assert_equal "r2", StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => "r2" })
  end

  test "an unknown stage raises instead of falling back to S3" do
    assert_raises(ArgumentError) { StorageBackend.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => "R2" }) }
    assert_raises(ArgumentError) { StorageBackend.studio_s3_stage({ "STUDIO_S3_BACKEND" => "mirror_to_r2" }) }
  end

  # --- Studio::S3 settings --------------------------------------------------------

  test "the S3 stage sets nothing, so the engine keeps its AWS defaults" do
    assert_equal({}, StorageBackend.studio_s3_settings({}))
    assert_equal({}, StorageBackend.studio_s3_settings(R2_ENV.merge("R2_PUBLIC_URL" => R2_PUBLIC_URL)))
  end

  test "the r2 stage sets the endpoint, region, key pair and public URL" do
    env = R2_ENV.merge("STUDIO_S3_BACKEND" => "r2", "R2_PUBLIC_URL" => R2_PUBLIC_URL)

    assert_equal({
      s3_endpoint: R2_ENDPOINT,
      s3_region: "auto",
      s3_access_key_id: "r2-sentinel-id",
      s3_secret_access_key: "r2-sentinel-secret",
      s3_public_url: R2_PUBLIC_URL
    }, StorageBackend.studio_s3_settings(env))
  end

  # The hub hands out public Studio::S3 URLs (ImageCache, broadcasts, lineups), and
  # Studio::S3.url raises on R2 without a public base, so r2 without one must not boot.
  test "the r2 stage refuses to boot without R2_PUBLIC_URL" do
    error = assert_raises(ArgumentError) { StorageBackend.studio_s3_settings(R2_ENV.merge("STUDIO_S3_BACKEND" => "r2")) }
    assert_match(/R2_PUBLIC_URL/, error.message)
  end

  test "the r2 stage refuses a missing credential rather than using AWS keys" do
    env = R2_ENV.except("R2_SECRET_ACCESS_KEY").merge("STUDIO_S3_BACKEND" => "r2", "R2_PUBLIC_URL" => R2_PUBLIC_URL)
    error = assert_raises(ArgumentError) { StorageBackend.studio_s3_settings(env) }
    assert_match(/R2_SECRET_ACCESS_KEY/, error.message)
  end

  test "the booted test app left Studio::S3 on its AWS defaults" do
    assert_nil Studio.s3_endpoint
    assert_nil Studio.s3_public_url
    assert_nil Studio.s3_access_key_id
  end

  # --- Active Storage: what each durable service resolves to at each stage --------

  def storage_configs(stage, extra = {})
    with_env(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => stage, "QA_ENV" => nil).merge(extra)) do
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    end
  end

  def service(name, stage)
    ActiveStorage::Service::Configurator.build(name, storage_configs(stage))
  end

  def endpoint_of(service) = service.client.client.config.endpoint.to_s

  # Byte-identical: the unconfigured render is exactly the pre-R2 file's services.
  test "s3 stage renders exactly the services the file had before R2" do
    s3 = { "service" => "S3", "access_key_id" => "AKIAEXAMPLEONLYTEST",
           "secret_access_key" => "aws-sentinel-secret", "region" => "us-east-2" }
    expected = {
      "test" => { "service" => "Disk", "root" => Rails.root.join("tmp/storage").to_s },
      "local" => { "service" => "Disk", "root" => Rails.root.join("storage").to_s },
      "amazon" => s3.merge("bucket" => "mcritchie-studio-production"),
      "amazon_dev" => s3.merge("bucket" => "mcritchie-studio-dev")
    }
    assert_equal expected, storage_configs("s3").deep_stringify_keys
    assert_equal expected, storage_configs(nil).deep_stringify_keys

    blank = storage_configs("s3", "AWS_ACCESS_KEY_ID" => "", "AWS_SECRET_ACCESS_KEY" => " ")
    assert_equal [ nil, nil ], blank["amazon"].values_at("access_key_id", "secret_access_key"),
                 "a blank key rendered nil in the old YAML, so the SDK's default chain applied"
  end

  %i[amazon amazon_dev].each do |name|
    bucket = name == :amazon ? "mcritchie-studio-production" : "mcritchie-studio-dev"

    test "#{name} s3 stage: the AWS service, unchanged" do
      svc = service(name, "s3")
      assert_instance_of ActiveStorage::Service::S3Service, svc
      assert_match(/amazonaws\.com/, endpoint_of(svc))
      assert_equal bucket, svc.bucket.name
    end

    test "#{name} mirror_to_r2: S3 is primary and R2 receives every write" do
      svc = service(name, "mirror_to_r2")
      assert_instance_of ActiveStorage::Service::MirrorService, svc
      assert_match(/amazonaws\.com/, endpoint_of(svc.primary))
      assert_equal [ R2_ENDPOINT ], svc.mirrors.map { |m| endpoint_of(m) }
      assert_equal [ bucket, bucket ], [ svc.primary, *svc.mirrors ].map { |s| s.bucket.name }
    end

    test "#{name} mirror_to_s3: R2 is primary and S3 still receives every write" do
      svc = service(name, "mirror_to_s3")
      assert_instance_of ActiveStorage::Service::MirrorService, svc
      assert_equal R2_ENDPOINT, endpoint_of(svc.primary)
      assert_equal 1, svc.mirrors.size
      assert_match(/amazonaws\.com/, endpoint_of(svc.mirrors.first))
    end

    test "#{name} r2 stage: R2 alone, same bucket name, R2 keys" do
      svc = service(name, "r2")
      assert_instance_of ActiveStorage::Service::S3Service, svc
      assert_equal R2_ENDPOINT, endpoint_of(svc)
      assert_equal bucket, svc.bucket.name
      assert_equal "r2-sentinel-id", svc.client.client.config.credentials.access_key_id
    end

    # Active Storage sends Content-MD5 and aws-sdk-s3 >= 1.178 adds a CRC32 by
    # default; R2 refuses both at once ("only one non-default checksum").
    test "#{name}: every R2 service computes checksums only when required" do
      [ service(name, "r2"), service(name, "mirror_to_r2").mirrors.first, service(name, "mirror_to_s3").primary ].each do |svc|
        assert_equal R2_ENDPOINT, endpoint_of(svc)
        assert_equal "when_required", svc.client.client.config.request_checksum_calculation
        assert_equal "when_required", svc.client.client.config.response_checksum_validation
      end
    end
  end

  test "QA_ENV still picks the dev bucket for amazon on R2" do
    svc = ActiveStorage::Service::Configurator.build(:amazon, storage_configs("r2", "QA_ENV" => "true"))
    assert_equal "mcritchie-studio-dev", svc.bucket.name
  end

  test "a non-S3 stage without R2 credentials fails at parse, not at first upload" do
    error = assert_raises(ArgumentError) { storage_configs("mirror_to_r2", "R2_ENDPOINT" => nil) }
    assert_match(/R2_ENDPOINT/, error.message)
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

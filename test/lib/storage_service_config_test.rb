require "test_helper"

# Active Storage requires service adapters lazily — Configurator only loads the
# one it is asked to build — so the Disk adapter this test refutes against is
# not defined unless we ask for it.
require "active_storage/service/disk_service"

# The config/storage.yml half of the QA/production bucket separation guard —
# the mcritchie-studio sibling of mcritchie-industries'
# test/lib/storage_service_config_test.rb, where the pattern (and each
# hard-won assertion style below) was first proven.
#
# mcritchie-studio-qa boots RAILS_ENV=production, so it loads the :amazon
# service. Before this guard the bucket was the hardcoded production name; the
# misresolution was MASKED only by QA carrying no storage key. The day QA gets a
# key, uploads SUCCEED into production storage — worse than a refusal.
#
# The store is Cloudflare R2 (AWS was retired 2026-10-10); the service keeps the
# name `amazon` because blob rows record it.
#
# These assertions run against the service OBJECT Active Storage builds, not
# the YAML text, so a typo or a fallback cannot pass them.
class StorageServiceConfigTest < ActiveSupport::TestCase
  DURABLE_SERVICE = :amazon
  EXPECTED_REGION = "auto".freeze # R2's region string
  R2_ENDPOINT = "https://sentinel-account.r2.cloudflarestorage.com".freeze

  PRODUCTION_BUCKET = "mcritchie-studio-production".freeze
  QA_BUCKET = "mcritchie-studio-dev".freeze

  # Sentinels: never real, never reach storage (no network calls here), but must
  # be values the real ENV would never hold or the ENV-sourcing assertion proves
  # nothing.
  SENTINEL_KEY_ID = "r2-sentinel-key-id-only-test".freeze
  SENTINEL_SECRET = "sentinel-secret-never-real".freeze

  # Parsed exactly the way ActiveStorage::Engine parses it, ERB and all, so
  # this reads the same configuration a booted dyno would.
  def storage_configs
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
  end

  # QA_ENV is set EXPLICITLY on every build — including to nil, which deletes
  # it — so the bucket assertions run on the config, never on whatever the
  # operator's shell happened to export.
  def build_durable_service(qa: false)
    with_env(
      "QA_ENV" => (qa ? "true" : nil),
      "ACTIVE_STORAGE_BACKEND" => nil,
      "R2_ENDPOINT" => R2_ENDPOINT,
      "R2_ACCESS_KEY_ID" => SENTINEL_KEY_ID,
      "R2_SECRET_ACCESS_KEY" => SENTINEL_SECRET
    ) do
      ActiveStorage::Service::Configurator.build(DURABLE_SERVICE, storage_configs)
    end
  end

  # storage_configs re-parses (so re-renders) on every call — this reads the
  # bucket the ERB actually produces under that ENV, not a cached parse.
  def resolved_bucket(qa:)
    build_durable_service(qa: qa).bucket.name
  end

  def with_env(vars)
    original = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "the durable service is the S3-API trash service on R2, never a local disk" do
    service = build_durable_service

    assert_kind_of ActiveStorage::Service::S3Service, service
    assert_instance_of ActiveStorage::Service::StudioTrashS3Service, service
    assert_equal R2_ENDPOINT, service.client.client.config.endpoint.to_s
    refute_kind_of ActiveStorage::Service::DiskService, service,
                   "#{DURABLE_SERVICE} must not be a Disk service — Heroku's dyno " \
                   "filesystem is ephemeral"
  end

  # Acceptance #2: production resolution stays byte-identical. The production
  # case is CONSTRUCTED (QA_ENV deleted) and pinned to the exact bucket name a
  # truthiness bug would move.
  test "each deployed environment targets its own provisioned bucket on R2" do
    assert_equal PRODUCTION_BUCKET, resolved_bucket(qa: false)
    assert_equal QA_BUCKET, resolved_bucket(qa: true)

    assert_equal EXPECTED_REGION, build_durable_service(qa: false).client.client.config.region
    assert_equal EXPECTED_REGION, build_durable_service(qa: true).client.client.config.region
  end

  # THE separation guard. Asserted as a DIFFERENCE, not two equalities: a test
  # pinning production to its literal keeps passing after a copy-paste
  # collapses QA onto the same name — exactly the failure mode. Both names also
  # asserted present, because one nil and one real would DIFFER and sail
  # through the inequality alone.
  test "QA and production resolve DIFFERENT buckets" do
    production = resolved_bucket(qa: false)
    qa = resolved_bucket(qa: true)

    assert production.present?, "the production environment must resolve a bucket name"
    assert qa.present?, "the QA environment must resolve a bucket name"

    assert_not_equal production, qa,
                     "mcritchie-studio and mcritchie-studio-qa BOTH boot as " \
                     "RAILS_ENV=production, so QA_ENV is the only thing separating " \
                     "their storage — and both resolved to #{production.inspect}."
  end

  # Unset, "", "false", "0", and unrecognised values must all resolve
  # PRODUCTION — EnvironmentBanner.truthy? is an allow-list, and this pins the
  # fail-safe direction so a truthiness rewrite cannot quietly flip it.
  test "only an allow-listed QA_ENV resolves the dev bucket" do
    [ nil, "", "false", "0", "off", "banana" ].each do |value|
      with_env("QA_ENV" => value,
               "R2_ENDPOINT" => R2_ENDPOINT,
               "R2_ACCESS_KEY_ID" => SENTINEL_KEY_ID,
               "R2_SECRET_ACCESS_KEY" => SENTINEL_SECRET) do
        service = ActiveStorage::Service::Configurator.build(DURABLE_SERVICE, storage_configs)
        assert_equal PRODUCTION_BUCKET, service.bucket.name,
                     "QA_ENV=#{value.inspect} must fail safe to production"
      end
    end
  end

  # Asserting on the RENDERED CONFIG rather than the built client is
  # deliberate: aws-sdk's own credential chain reads AWS_ACCESS_KEY_ID from the
  # process environment, so a client built from a config with NO credentials
  # can still carry a key — measured in the industries sibling, where the
  # client-inspecting version passed while guarding nothing.
  def rendered_credentials(key_id:, secret:)
    with_env("R2_ACCESS_KEY_ID" => key_id, "R2_SECRET_ACCESS_KEY" => secret) do
      config = storage_configs.fetch(DURABLE_SERVICE.to_s)
      [ config["access_key_id"], config["secret_access_key"] ]
    end
  end

  test "credentials track ENV, not Rails credentials or a hardcoded literal" do
    assert_equal [ SENTINEL_KEY_ID, SENTINEL_SECRET ],
                 rendered_credentials(key_id: SENTINEL_KEY_ID, secret: SENTINEL_SECRET),
                 "storage.yml must read the R2 credentials out of ENV"

    assert_equal [ "second-sentinel-id", "second-sentinel-secret" ],
                 rendered_credentials(key_id: "second-sentinel-id", secret: "second-sentinel-secret"),
                 "the rendered credentials must follow ENV, not merely match it once"
  end

  # The dyno's AWS_* variables are gone, and a stray one (a laptop's shell, an
  # old .env) must not leak into the rendered service.
  test "an AWS key in the environment never reaches the rendered service" do
    with_env("AWS_ACCESS_KEY_ID" => "AKIASTRAYEXAMPLE", "AWS_SECRET_ACCESS_KEY" => "stray-secret",
             "R2_ACCESS_KEY_ID" => SENTINEL_KEY_ID, "R2_SECRET_ACCESS_KEY" => SENTINEL_SECRET) do
      rendered = storage_configs.to_json
      refute_includes rendered, "AKIASTRAYEXAMPLE"
      refute_includes rendered, "stray-secret"
    end
  end
end

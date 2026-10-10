# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "etc"

# [integration] THE STORAGE BOOT MATRIX, in real processes. A bad storage config
# once passed Heroku's release phase and then crash-looped web and worker
# (docs/agents/system/r2-cutover-record.md), because config/storage.yml is
# rendered lazily and the release phase's rake task never renders it. So the
# refusals here are asked of `bin/rake environment`, which boots exactly as far
# as the release phase's db:migrate does, and each must exit non-zero there.
#
# Rails.env is fixed per process, so every case is its own child, started
# together and joined. Each child gets this test's database and an explicit
# value for every storage variable: nil unsets it, and "" is passed where a
# desk's own .env.development (dotenv loads it in development) would otherwise
# supply real R2 keys and hide the keyless case.
#
#   production, every R2 variable            boots; amazon is the trash service
#   production + QA_ENV, switches unset      boots; amazon names the dev bucket
#   production, no R2 variable               refuses, naming R2_ENDPOINT
#   production, no R2_PUBLIC_URL             refuses, naming R2_PUBLIC_URL
#   production, ACTIVE_STORAGE_BACKEND=s3    refuses, naming the variable
#   production, STUDIO_S3_BACKEND=s3         refuses, naming the variable
#   development, no R2 variable (keyless)    boots, on the placeholder host
class StorageBootMatrixTest < ActiveSupport::TestCase
  ROOT = Rails.root.to_s
  STORAGE_VARS = %w[ACTIVE_STORAGE_BACKEND STUDIO_S3_BACKEND R2_ENDPOINT R2_ACCESS_KEY_ID
                    R2_SECRET_ACCESS_KEY R2_PUBLIC_URL QA_ENV AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze
  R2 = {
    "R2_ENDPOINT" => "https://boot-matrix.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "boot-matrix-id",
    "R2_SECRET_ACCESS_KEY" => "boot-matrix-secret",
    "R2_PUBLIC_URL" => "https://assets.boot-matrix.example"
  }.freeze

  # What a booted child reports: the service the environment selected, built.
  REPORT = <<~RUBY
    service = ActiveStorage::Blob.service
    puts "BOOT-REPORT " + {
      env: Rails.env, eager_load: Rails.application.config.eager_load,
      service: service.class.name, bucket: service.bucket.name,
      endpoint: service.client.client.config.endpoint.to_s,
      studio_endpoint: Studio.s3_endpoint, studio_public_url: Studio.s3_public_url,
      studio_bucket: Studio::S3.bucket
    }.to_json
  RUBY

  CASES = {
    production_full: { rails_env: "production", command: :report,
                       vars: R2.merge("ACTIVE_STORAGE_BACKEND" => "r2", "STUDIO_S3_BACKEND" => "r2") },
    qa_switches_unset: { rails_env: "production", command: :report, vars: R2.merge("QA_ENV" => "true") },
    production_keyless: { rails_env: "production", command: :release, vars: {} },
    production_no_public_url: { rails_env: "production", command: :release, vars: R2.except("R2_PUBLIC_URL") },
    production_active_storage_s3: { rails_env: "production", command: :release,
                                    vars: R2.merge("ACTIVE_STORAGE_BACKEND" => "s3") },
    production_studio_s3: { rails_env: "production", command: :release, vars: R2.merge("STUDIO_S3_BACKEND" => "s3") },
    development_keyless: { rails_env: "development", command: :report,
                           vars: R2.transform_values { "" }.merge("ACTIVE_STORAGE_BACKEND" => "", "STUDIO_S3_BACKEND" => "") }
  }.freeze

  Outcome = Struct.new(:status, :output, :report, keyword_init: true)

  # Every child boots once per run of this file; each test reads its own case.
  def self.outcomes
    @outcomes ||= CASES.map { |name, spec| [ name, Thread.new { boot(spec) } ] }.to_h { |name, t| [ name, t.value ] }
  end

  # This test's database as a URL (a parallel worker's own database included).
  # Nothing is written. The username is always spelled out: database.yml's
  # production block names its own, which would win over a URL without one.
  def self.database_url
    c = ActiveRecord::Base.connection_db_config.configuration_hash
    user = c[:username].presence || Etc.getpwuid.name
    auth = c[:password].present? ? "#{user}:#{c[:password]}" : user
    "postgresql://#{auth}@#{c[:host].presence || 'localhost'}#{":#{c[:port]}" if c[:port]}/#{c[:database]}"
  end

  def self.boot(spec)
    env = STORAGE_VARS.to_h { |name| [ name, nil ] }.merge(spec[:vars]).merge(
      "RAILS_ENV" => spec[:rails_env], "DATABASE_URL" => database_url,
      "SECRET_KEY_BASE" => "storage-boot-matrix-not-a-real-secret", "RAILS_LOG_LEVEL" => "fatal"
    )
    argv = if spec[:command] == :release
      [ RbConfig.ruby, File.join(ROOT, "bin/rake"), "environment" ]
    else
      [ RbConfig.ruby, File.join(ROOT, "bin/rails"), "runner", REPORT ]
    end
    output, status = Open3.capture2e(env, *argv, chdir: ROOT)
    line = output.lines.find { |l| l.start_with?("BOOT-REPORT ") }
    Outcome.new(status: status.exitstatus, output: output,
                report: line && JSON.parse(line.delete_prefix("BOOT-REPORT ")))
  end

  def outcome(name) = self.class.outcomes.fetch(name)

  def booted(name)
    result = outcome(name)
    assert_equal 0, result.status, "#{name} did not boot:\n#{result.output.lines.first(12).join}"
    refute_nil result.report, "#{name} booted but reported nothing:\n#{result.output}"
    result.report
  end

  def refused(name)
    result = outcome(name)
    refute_equal 0, result.status, "#{name} booted; a bad storage config must fail the release phase"
    result.output
  end

  test "production with every R2 variable boots on the trash service and the production bucket" do
    report = booted(:production_full)
    assert_equal "production", report["env"]
    assert report["eager_load"], "not a production boot"
    assert_equal "ActiveStorage::Service::StudioTrashS3Service", report["service"]
    assert_equal "mcritchie-studio-production", report["bucket"]
    assert_equal R2["R2_ENDPOINT"], report["endpoint"]
    assert_equal R2["R2_ENDPOINT"], report["studio_endpoint"]
    assert_equal R2["R2_PUBLIC_URL"], report["studio_public_url"]
    assert_equal "mcritchie-studio-production", report["studio_bucket"]
  end

  test "QA with both switches unset boots on R2 and the dev bucket for both writers" do
    report = booted(:qa_switches_unset)
    assert_equal "production", report["env"]
    assert_equal "ActiveStorage::Service::StudioTrashS3Service", report["service"]
    assert_equal "mcritchie-studio-dev", report["bucket"]
    assert_equal "mcritchie-studio-dev", report["studio_bucket"]
    assert_equal R2["R2_ENDPOINT"], report["endpoint"], "unset must mean R2, never S3"
    assert_equal R2["R2_ENDPOINT"], report["studio_endpoint"]
  end

  test "production with no R2 variable fails the release phase naming the variable" do
    assert_match(/R2_ENDPOINT must be set/, refused(:production_keyless))
  end

  test "production without R2_PUBLIC_URL fails the release phase naming it" do
    output = refused(:production_no_public_url)
    assert_match(/R2_PUBLIC_URL must be set/, output)
    refute_match(/R2_ENDPOINT must be set/, output)
  end

  test "production with ACTIVE_STORAGE_BACKEND=s3 fails the release phase naming it" do
    assert_match(/ACTIVE_STORAGE_BACKEND="s3" names a retired stage/, refused(:production_active_storage_s3))
  end

  test "production with STUDIO_S3_BACKEND=s3 fails the release phase naming it" do
    assert_match(/STUDIO_S3_BACKEND="s3" names a retired stage/, refused(:production_studio_s3))
  end

  test "a keyless development boot loads storage.yml and builds its service on the placeholder" do
    report = booted(:development_keyless)
    assert_equal "development", report["env"]
    assert_equal "ActiveStorage::Service::StudioTrashS3Service", report["service"]
    assert_equal "mcritchie-studio-dev", report["bucket"]
    assert_equal "https://r2-not-configured.invalid", report["endpoint"]
    assert_equal "https://r2-not-configured.invalid", report["studio_endpoint"]
  end

  # The test environment IS the CI boot: no R2 variable, and it got this far.
  test "the test environment itself booted without any R2 variable requirement" do
    refute StorageBackend.strict?
    parsed = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    assert_equal %w[amazon amazon_dev local test], parsed.keys.map(&:to_s).sort
  end
end

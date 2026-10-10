require "test_helper"

# [unit] DeskCapture's storage backend: which bucket, endpoint and keys the
# client is built with. Cloudflare R2 is the only backend (the S3 half and the
# SES poll job were deleted on 2026-10-10 with the AWS exit), so these pin that
# no configuration can build an AWS client. Building an Aws::S3::Client makes no
# network call, so nothing here reaches storage.
class DeskCaptureBackendTest < ActiveSupport::TestCase
  R2_ENV = {
    "DESK_CAPTURE_R2_ENDPOINT" => "https://acct123.r2.cloudflarestorage.com",
    "DESK_CAPTURE_R2_ACCESS_KEY_ID" => "r2-key-id",
    "DESK_CAPTURE_R2_SECRET_ACCESS_KEY" => "r2-secret"
  }.freeze

  KEYS = (R2_ENV.keys + %w[DESK_CAPTURE_BACKEND DESK_CAPTURE_BUCKET DESK_CAPTURE_REGION
                           AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY]).freeze

  setup do
    @saved = KEYS.index_with { |k| ENV[k] }
    KEYS.each { |k| ENV.delete(k) }
    DeskCapture.reset!
  end

  teardown do
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    DeskCapture.reset!
  end

  test "the client targets the R2 endpoint with the desk keys, backend unset" do
    R2_ENV.each { |k, v| ENV[k] = v }

    assert_equal "mcritchie-studio-desk", DeskCapture.bucket
    config = DeskCapture.client.config
    assert_equal "https://acct123.r2.cloudflarestorage.com", config.endpoint.to_s
    assert_equal "auto", config.region
    assert_equal "r2-key-id", config.credentials.access_key_id
    assert_equal "r2-secret", config.credentials.secret_access_key
  end

  test "the live value DESK_CAPTURE_BACKEND=r2 stays valid, in any case" do
    R2_ENV.each { |k, v| ENV[k] = v }

    %w[r2 R2].each do |value|
      with_env("DESK_CAPTURE_BACKEND", value) do
        assert_equal "r2", DeskCapture.backend!
        assert_equal "auto", DeskCapture.client_options[:region]
      end
    end
  end

  test "an old backend value raises instead of building any client" do
    R2_ENV.each { |k, v| ENV[k] = v }
    ENV["AWS_ACCESS_KEY_ID"] = "aws-id"
    ENV["AWS_SECRET_ACCESS_KEY"] = "aws-secret"

    %w[s3 aws ses].each do |value|
      with_env("DESK_CAPTURE_BACKEND", value) do
        error = assert_raises(ArgumentError) { DeskCapture.client }
        assert_includes error.message, "DESK_CAPTURE_BACKEND=#{value.inspect}"
        assert_match(/R2 only/, error.message)
      end
    end
    assert_nil DeskCapture.instance_variable_get(:@client)
  end

  test "the app's AWS keys are never used" do
    ENV["AWS_ACCESS_KEY_ID"] = "aws-id"
    ENV["AWS_SECRET_ACCESS_KEY"] = "aws-secret"
    R2_ENV.each { |k, v| ENV[k] = v }

    assert_equal "r2-key-id", DeskCapture.client.config.credentials.access_key_id
    refute_match(/amazonaws/, DeskCapture.client.config.endpoint.to_s)
  end

  # No keys at all (QA, a local desk): there is no S3 default to fall back to.
  test "with only AWS keys in the environment no client is built" do
    ENV["AWS_ACCESS_KEY_ID"] = "aws-id"
    ENV["AWS_SECRET_ACCESS_KEY"] = "aws-secret"

    error = assert_raises(KeyError) { DeskCapture.client }
    assert_includes error.message, "DESK_CAPTURE_R2_ENDPOINT"
  end

  R2_ENV.each_key do |missing|
    test "a missing #{missing} fails loudly naming it" do
      R2_ENV.except(missing).each { |k, v| ENV[k] = v }

      error = assert_raises(KeyError) { DeskCapture.client }
      assert_includes error.message, missing
    end
  end

  test "a bucket override still applies" do
    with_env("DESK_CAPTURE_BUCKET", "other-desk") { assert_equal "other-desk", DeskCapture.bucket }
  end

  # DESK_CAPTURE_REGION belonged to the S3 backend (us-east-1). A stale one on a
  # dyno must not move the R2 client off `auto`.
  test "a stale DESK_CAPTURE_REGION is ignored" do
    R2_ENV.each { |k, v| ENV[k] = v }
    with_env("DESK_CAPTURE_REGION", "us-east-1") { assert_equal "auto", DeskCapture.client_options[:region] }
  end

  test "the S3 half and the SES poll job are gone" do
    %i[r2? region configured? list_incoming_keys].each do |name|
      refute_respond_to DeskCapture, name
    end
    refute DeskCapture.const_defined?(:INCOMING_PREFIX)
    refute Rails.root.join("app/jobs/desk_capture_poll_job.rb").exist?
    assert_nil "DeskCapturePollJob".safe_constantize
  end

  # A schedule entry naming a deleted job class crashes the scheduler at boot.
  test "every recurring job class in config/recurring.yml still exists" do
    schedule = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    classes = schedule.values.grep(Hash).flat_map { |env| env.values.grep(Hash).filter_map { |job| job["class"] } }
    refute_empty classes
    refute_includes classes, "DeskCapturePollJob"
    classes.each { |name| assert name.safe_constantize, "config/recurring.yml names #{name}, which does not exist" }
  end
end

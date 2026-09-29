require "test_helper"

# [unit] DeskCapture's storage backend: which bucket, endpoint and keys the
# client is built with. DESK_CAPTURE_BACKEND=r2 moves it to the private R2
# bucket; unset, it is byte-for-byte the S3 client it always was. Building an
# Aws::S3::Client makes no network call, so nothing here reaches storage.
class DeskCaptureBackendTest < ActiveSupport::TestCase
  R2_ENV = {
    "DESK_CAPTURE_BACKEND" => "r2",
    "DESK_CAPTURE_R2_ENDPOINT" => "https://acct123.r2.cloudflarestorage.com",
    "DESK_CAPTURE_R2_ACCESS_KEY_ID" => "r2-key-id",
    "DESK_CAPTURE_R2_SECRET_ACCESS_KEY" => "r2-secret"
  }.freeze

  KEYS = (R2_ENV.keys + %w[DESK_CAPTURE_BUCKET DESK_CAPTURE_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY]).freeze

  setup do
    @saved = KEYS.index_with { |k| ENV[k] }
    KEYS.each { |k| ENV.delete(k) }
    DeskCapture.reset!
  end

  teardown do
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    DeskCapture.reset!
  end

  test "without R2 config the S3 bucket, region and client are unchanged" do
    refute DeskCapture.r2?
    assert_equal "mcritchie-studio-desk", DeskCapture.bucket
    assert_equal "us-east-1", DeskCapture.region

    # Env keys stand in for the dyno's so the SDK's chain never probes IMDS.
    ENV["AWS_ACCESS_KEY_ID"] = "aws-id"
    ENV["AWS_SECRET_ACCESS_KEY"] = "aws-secret"
    config = DeskCapture.client.config
    assert_equal "us-east-1", config.region
    assert_match(/\.amazonaws\.com\z/, config.endpoint.host)
    assert_equal "aws-id", config.credentials.access_key_id
  end

  test "S3 configured? still keys off the app's AWS credentials" do
    refute DeskCapture.configured?
    with_env("AWS_ACCESS_KEY_ID", "aws-id") { assert DeskCapture.configured? }
  end

  test "an S3 bucket override still applies" do
    with_env("DESK_CAPTURE_BUCKET", "other-desk") { assert_equal "other-desk", DeskCapture.bucket }
  end

  test "with R2 config the client targets the R2 endpoint with the desk keys" do
    R2_ENV.each { |k, v| ENV[k] = v }

    assert DeskCapture.r2?
    assert DeskCapture.configured?, "R2 backend is configured without any AWS_* key"
    assert_equal "mcritchie-studio-desk", DeskCapture.bucket
    assert_equal "auto", DeskCapture.region

    config = DeskCapture.client.config
    assert_equal "https://acct123.r2.cloudflarestorage.com", config.endpoint.to_s
    assert_equal "auto", config.region
    assert_equal "r2-key-id", config.credentials.access_key_id
    assert_equal "r2-secret", config.credentials.secret_access_key
  end

  test "R2 never falls back to the app's AWS keys" do
    ENV["AWS_ACCESS_KEY_ID"] = "aws-id"
    R2_ENV.each { |k, v| ENV[k] = v }

    assert_equal "r2-key-id", DeskCapture.client.config.credentials.access_key_id
  end

  test "R2 selected with a missing key fails loudly naming it" do
    R2_ENV.except("DESK_CAPTURE_R2_SECRET_ACCESS_KEY").each { |k, v| ENV[k] = v }

    error = assert_raises(KeyError) { DeskCapture.client }
    assert_includes error.message, "DESK_CAPTURE_R2_SECRET_ACCESS_KEY"
  end

  test "the backend switch is case-insensitive and ignores other values" do
    with_env("DESK_CAPTURE_BACKEND", "R2") { assert DeskCapture.r2? }
    with_env("DESK_CAPTURE_BACKEND", "s3") { refute DeskCapture.r2? }
  end
end

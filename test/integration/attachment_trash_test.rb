require "test_helper"

# [integration] Purging or replacing an attachment TRASHES the object rather
# than hard-deleting it. R2 has no object versioning, so the hub's durable Active
# Storage services are studio-engine's StudioTrashS3 (config/storage.yml,
# config/initializers/00_storage_backend.rb): delete copies the object to
# trash/<utc date>/<epoch ms>/<key>, and only then deletes the original. The
# bucket's `expire-trash-3d` lifecycle rule removes the trash copy after three
# days.
#
# The services are built from the hub's real config/storage.yml, parsed the way
# Active Storage parses it, with one addition: `stub_responses: true`, which the
# S3 service hands to the AWS SDK. Every call is answered locally and recorded
# in `api_requests`, so no request leaves the process.
class AttachmentTrashTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  R2_ENV = {
    "R2_ENDPOINT" => "https://sentinel-account.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "r2-sentinel-id",
    "R2_SECRET_ACCESS_KEY" => "r2-sentinel-secret",
    "ACTIVE_STORAGE_BACKEND" => nil,
    "QA_ENV" => nil
  }.freeze
  TRASH_KEY = %r{\Atrash/\d{4}-\d{2}-\d{2}/\d{13}/}

  setup do
    @original_services = ActiveStorage::Blob.services
    install_services
  end

  teardown do
    ActiveStorage::Blob.services = @original_services
  end

  test "the hub's durable services are the engine's trash service" do
    %w[amazon amazon_dev].each do |name|
      assert_instance_of ActiveStorage::Service::StudioTrashS3Service, ActiveStorage::Blob.services.fetch(name)
    end
  end

  test "purging a blob copies it to trash and only then deletes the original" do
    blob = upload("report.pdf")
    reset_requests

    blob.purge

    names = operations
    assert_includes names, :copy_object
    assert_includes names, :delete_object
    assert_operator names.index(:copy_object), :<, names.index(:delete_object),
                    "the delete was sent before the trash copy: #{names.inspect}"

    copy = request(:copy_object)
    assert_equal "mcritchie-studio-dev", copy[:bucket]
    assert_equal "mcritchie-studio-dev/#{blob.key}", copy[:copy_source]
    assert_match TRASH_KEY, copy[:key]
    assert copy[:key].end_with?("/#{blob.key}"), "the trash key does not end in the original key"
    assert_equal blob.key, copy[:metadata]["original-key"]
    assert_equal "test", copy[:metadata]["deleted-env"]

    delete = request(:delete_object)
    assert_equal({ bucket: "mcritchie-studio-dev", key: blob.key }, delete)
    assert_equal 1, names.count(:delete_object), "exactly the original is deleted, never the trash copy"
    refute ActiveStorage::Blob.exists?(blob.id)
  end

  # THE ORDER IS THE SAFETY: a copy that fails must leave the original in place.
  test "a failed trash copy raises and sends no delete" do
    blob = upload("report.pdf")
    reset_requests
    client.stub_responses(:copy_object, "AccessDenied")

    assert_raises(Aws::S3::Errors::AccessDenied) { blob.purge }

    assert_includes operations, :copy_object
    refute_includes operations, :delete_object
  end

  test "an object that is already gone is neither copied nor deleted" do
    blob = upload("report.pdf")
    reset_requests
    client.stub_responses(:head_object, "NotFound")

    blob.purge

    refute_includes operations, :copy_object
    refute_includes operations, :delete_object
  end

  test "replacing a user's avatar trashes the old object" do
    user = users(:viewer)
    first = upload("first.png", content_type: "image/png")
    user.avatar.attach(first)
    reset_requests

    # Only the purge: an AnalyzeJob would download the new blob from the
    # stubbed client, whose empty body fails Active Storage's integrity check.
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      user.avatar.attach(upload("second.png", content_type: "image/png"))
    end

    copies = requests(:copy_object)
    assert_equal [ "mcritchie-studio-dev/#{first.key}" ], copies.map { |c| c[:copy_source] }
    assert_match TRASH_KEY, copies.first[:key]
    assert_equal [ first.key ], requests(:delete_object).map { |d| d[:key] }
    assert_operator operations.index(:copy_object), :<, operations.index(:delete_object)
  end

  # --- the engine's production-bucket guard, against the hub's own config --------
  #
  # The service refuses to delete from a "*-production" bucket unless the
  # process is real production (Studio::S3.production_environment?, which reads
  # QA_ENV first and then Rails.env).

  test "production deletes from the production bucket, through the trash" do
    blob = upload("report.pdf", service_name: "amazon")
    reset_requests("amazon")

    Studio::S3.stub(:production_environment?, true) { blob.purge }

    copy = request(:copy_object, "amazon")
    assert_equal "mcritchie-studio-production", copy[:bucket]
    assert_match TRASH_KEY, copy[:key]
    assert_equal blob.key, request(:delete_object, "amazon")[:key]
  end

  test "a non-production process is refused on the production bucket and sends nothing" do
    blob = upload("report.pdf", service_name: "amazon")
    reset_requests("amazon")

    refute Studio::S3.production_environment?, "the test process must not read as production"
    assert_raises(Studio::S3::Trash::ProductionBucketRefused) { blob.purge }

    assert_empty operations("amazon") & %i[copy_object delete_object delete_objects]
  end

  # QA boots RAILS_ENV=production and loads `amazon`. The guard would refuse
  # every purge there if `amazon` named the production bucket, so QA_ENV must
  # resolve the dev bucket, which the guard lets through.
  test "QA's amazon service names the dev bucket, which the guard allows" do
    install_services("QA_ENV" => "true")
    bucket = ActiveStorage::Blob.services.fetch("amazon").bucket.name

    assert_equal "mcritchie-studio-dev", bucket
    assert_nil Studio::S3.guard_production_bucket!(bucket)

    blob = upload("report.pdf", service_name: "amazon")
    reset_requests("amazon")
    blob.purge
    assert_equal "mcritchie-studio-dev", request(:copy_object, "amazon")[:bucket]
  end

  test "local development's amazon_dev service names the dev bucket, which the guard allows" do
    bucket = ActiveStorage::Blob.services.fetch("amazon_dev").bucket.name
    assert_equal "mcritchie-studio-dev", bucket
    assert_nil Studio::S3.guard_production_bucket!(bucket)
  end

  private

  # config/storage.yml as Active Storage reads it, with the SDK stubbed.
  def install_services(extra = {})
    configs = with_env(R2_ENV.merge(extra)) do
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    end
    %w[amazon amazon_dev].each { |name| configs[name] = configs.fetch(name).merge("stub_responses" => true) }
    ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(configs)
  end

  def client(service = "amazon_dev") = ActiveStorage::Blob.services.fetch(service).client.client

  def upload(filename, service_name: "amazon_dev", content_type: "application/pdf")
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("bytes of #{filename}"), filename: filename,
                                           content_type: content_type, identify: false, service_name: service_name)
  end

  def reset_requests(service = "amazon_dev") = client(service).api_requests.clear

  def operations(service = "amazon_dev") = client(service).api_requests.map { |r| r[:operation_name] }

  def requests(operation, service = "amazon_dev")
    client(service).api_requests.select { |r| r[:operation_name] == operation }.map { |r| r[:params] }
  end

  def request(operation, service = "amazon_dev") = requests(operation, service).first

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

require "test_helper"

# [unit] TestStorageRoots: every parallel worker gets its own Active Storage disk,
# so two workers writing one key can no longer overwrite each other's object
# (the AppIntakeMoveTest flake on hub CI, release SHA 29029a4).
class TestStorageRootsTest < ActiveSupport::TestCase
  def configurations(base)
    {
      test: { service: "Disk", root: File.join(base, "storage") },
      chat_private: { "service" => "Disk", "root" => File.join(base, "storage_chat_private") },
      amazon: { service: "S3", bucket: "never-built" }
    }
  end

  # A registry per worker, as each forked worker holds its own copy of the parent's.
  def worker_registry(base, worker)
    configs = configurations(base)
    registry = ActiveStorage::Service::Registry.new(configs)
    TestStorageRoots.isolate!(worker, configurations: configs, registry: registry)
    registry
  ensure
    TestStorageRoots.instance_variable_set(:@worker, @live_worker)
  end

  setup { @live_worker = TestStorageRoots.worker }

  test "each worker's Disk services get a root of their own" do
    Dir.mktmpdir do |base|
      zero = worker_registry(base, 0)
      one = worker_registry(base, 1)

      assert_equal File.join(base, "storage", "worker-0"), zero.fetch(:test).root
      assert_equal File.join(base, "storage", "worker-1"), one.fetch(:test).root
      assert_equal File.join(base, "storage_chat_private", "worker-1"), one.fetch(:chat_private).root
      refute_equal zero.fetch(:chat_private).root, one.fetch(:chat_private).root
    end
  end

  test "two workers writing the same key each read back their own body" do
    Dir.mktmpdir do |base|
      zero = worker_registry(base, 0).fetch(:test)
      one = worker_registry(base, 1).fetch(:test)

      zero.upload("intake/tok_en-1/logo.png", StringIO.new("logo"))
      one.upload("intake/tok_en-1/logo.png", StringIO.new("bytes of intake/tok_en-1/logo.png"))

      assert_equal "logo", zero.download("intake/tok_en-1/logo.png"), "worker 0's object survives worker 1's write"
    end
  end

  test "only Disk services are touched; an S3 service is never built" do
    Dir.mktmpdir do |base|
      fetched = []
      registry = ActiveStorage::Service::Registry.new(configurations(base))
      spy = Object.new
      spy.define_singleton_method(:fetch) { |name| fetched << name; registry.fetch(name) }

      rehomed = TestStorageRoots.isolate!(2, configurations: configurations(base), registry: spy)
      TestStorageRoots.instance_variable_set(:@worker, @live_worker)

      assert_equal %i[test chat_private], fetched
      assert_equal %i[test chat_private], rehomed.keys
    end
  end

  test "the live services sit on this worker's roots, or on the configured roots when serial" do
    configured = Rails.configuration.active_storage.service_configurations
    expected = %w[test chat_private].to_h do |name|
      root = configured.fetch(name).fetch("root").to_s
      [ name, @live_worker.nil? ? root : TestStorageRoots.worker_root(root, @live_worker) ]
    end

    assert_equal expected["test"], ActiveStorage::Blob.service.root.to_s
    assert_equal expected["chat_private"], ActiveStorage::Blob.services.fetch(:chat_private).root.to_s
  end
end

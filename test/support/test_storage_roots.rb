# Each parallel test worker gets its OWN Active Storage disk.
#
# CI forks one worker per processor (parallelize in test_helper.rb). Each worker
# clones its own database, but config/storage.yml gives every Disk service ONE
# root (tmp/storage, tmp/storage_chat_private) — so two workers that write the
# same key at the same moment overwrite each other's object. That is how
# AppIntakeMoveTest read "bytes of intake/tok_en-1/logo.png" where it had written
# "logo" (hub CI, release SHA 29029a4): a sibling worker's test uploaded the
# same key with the default body between the write and the read.
#
# isolate! runs in parallelize_setup, after the fork, and nests the root of
# EVERY configured Disk service with the worker number (tmp/storage/worker-3).
# The registry caches one service object per name, and ActiveStorage::Blob.service is
# that same object, so mutating its root re-homes every later read and write in
# the worker. A serial run never calls it and keeps the configured roots. The
# subdirectory stays UNDER the configured root, so .gitignore and the artifact
# sweep (bin/lib/artifact_sweep.rb) keep covering it.
module TestStorageRoots
  class << self
    attr_reader :worker

    # Returns { service_name => new_root } for the Disk services it re-homed.
    def isolate!(worker,
                 configurations: Rails.configuration.active_storage.service_configurations,
                 registry: ActiveStorage::Blob.services)
      @worker = worker
      disk_service_names(configurations).to_h do |name|
        service = registry.fetch(name)
        service.root = worker_root(service.root, worker)
        [ name, service.root ]
      end
    end

    def worker_root(root, worker) = File.join(root.to_s, "worker-#{worker}")

    # Only Disk services carry a root; an S3 service is never built here (building
    # one would reach for credentials a test run does not have).
    def disk_service_names(configurations)
      (configurations || {}).filter_map do |name, config|
        name.to_sym if config.to_h.transform_keys(&:to_s)["service"].to_s == "Disk"
      end
    end
  end
end

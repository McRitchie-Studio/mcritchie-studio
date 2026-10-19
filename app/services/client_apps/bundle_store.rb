# frozen_string_literal: true

module ClientApps
  # Where client-app bundles live (docs/agents/system/client-app-host.md): one
  # object per file at
  #
  #   client-apps/<sub>/<version>/<path>
  #
  # in an Active Storage SERVICE (not as blobs: no rows, just objects), picked by
  # CLIENT_APP_BUNDLE_SERVICE, else:
  #
  #   production, QA  `chat_private`: the private R2 bucket pair
  #                   (mcritchie-studio-chat-production / -dev). It has NO public
  #                   domain. The hub bucket (`amazon`) is served to anyone at
  #                   assets.mcritchie.studio, which would put model-written HTML
  #                   on a mcritchie.studio origin, inside the session cookie's
  #                   reach; so bundles never go there.
  #   development     `local` (Disk, storage/)
  #   test            `test` (Disk, tmp/storage)
  #
  # A version's objects are written once and never changed, so a read is cached
  # in process (CACHE_BYTES, least recently used) and checked against the
  # manifest's sha256.
  module BundleStore
    PREFIX = "client-apps"
    SERVICE_ENV = "CLIENT_APP_BUNDLE_SERVICE"
    CACHE_BYTES = 64 * 1024 * 1024

    class NotReady < StandardError; end
    class Corrupt < StandardError; end

    module_function

    def key(sub, version, path) = "#{PREFIX}/#{sub}/#{version}/#{path}"

    def service_name(env = ENV)
      named = env[SERVICE_ENV].to_s.strip
      return named unless named.empty?
      return StorageBackend::CHAT_PRIVATE_SERVICE if Rails.env.production?

      Rails.env.test? ? "test" : "local"
    end

    def service = ActiveStorage::Blob.services.fetch(service_name.to_sym)

    # Why a publish cannot write here, or nil when it can: the private bucket's
    # keys are optional (StorageBackend.chat_private_configured?), and without
    # them the service points at a host that never resolves.
    def unready_reason(env = ENV)
      return nil unless service_name(env) == StorageBackend::CHAT_PRIVATE_SERVICE
      return nil if StorageBackend.chat_private_configured?(env)

      "client bundles are stored in the private chat bucket, whose keys are not set " \
        "(#{StorageBackend::CHAT_ENV.join(', ')})"
    end

    def write(key, bytes, content_type:)
      service.upload(key, StringIO.new(bytes), content_type: content_type)
    end

    # The bytes at KEY, which must hash to SHA256 (the manifest's), else Corrupt.
    def read(key, sha256:)
      cache.fetch("#{key}@#{sha256}") do
        bytes = service.download(key).b
        raise Corrupt, "#{key} does not match its manifest" unless Digest::SHA256.hexdigest(bytes) == sha256

        bytes
      end
    end

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: CACHE_BYTES)
    end

    def clear_cache! = cache.clear
  end
end

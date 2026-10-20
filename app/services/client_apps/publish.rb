# frozen_string_literal: true

module ClientApps
  # Publish one static bundle as an app's live preview
  # (docs/agents/system/client-app-host.md):
  #
  #   result = ClientApps::Publish.new(app:, files: { "index.html" => bytes, … }, by: "pokemon").call
  #   result.version            # "20261019T201500Z-1a2b3c4d"
  #   result.url                # "https://<sub>.mcritchie.app"
  #   result.event              # the preview_ready TaskEvent, or nil (no build task)
  #
  # 1. VALIDATE with ClientAppBundle (size, count, file types, paths, index.html).
  #    A refusal raises ClientAppBundle::Invalid and writes nothing.
  # 2. UPLOAD every file under client-apps/<sub>/<new version>/ (BundleStore).
  #    Nothing reads a version before step 3 names it, so a failed upload leaves
  #    only unreferenced objects behind and the live preview unchanged.
  # 3. FLIP, in one transaction holding the app's row lock: the history row
  #    (AppPreviewVersion, with the manifest), apps.preview_version, and the
  #    `preview_ready` checkpoint on the app's build task. A reader sees the old
  #    version or the new one, never a mix; the event exists exactly when the
  #    flip does.
  #
  # The callers: Api::V1::ClientBundlesController (bin/client-bundle against a
  # hub) and ClientApps::LocalPublish (bin/client-bundle --local on a desk).
  class Publish
    EVENT = "preview_ready"

    Result = Struct.new(:app, :version, :previous_version, :url, :event, :row, keyword_init: true)

    class Refused < StandardError; end

    def self.publishable_reason(app)
      return "no such app" unless app
      return "#{app.slug} is not a valid preview subdomain" unless app.slug.to_s.match?(ClientAppHost::LABEL)
      return "#{app.slug} is a reserved name (one of ours), never a client preview" if AppRequest.reserved_names.include?(app.slug)
      # The registry's own apps and libraries (config/apps.yml), the hub among
      # them: reserved_names misses any whose host is not under mcritchie.studio.
      return "#{app.slug} is one of ours (config/apps.yml), never a client preview" if registered_slug?(app.slug)
      # The allow-list, which the deny-lists above only back up: a client app is
      # one a /build request launched (AppLaunch, AppRequest#queue!), and that
      # request still holds its name. Any other App row (a hand-made one, a
      # satellite the lists above miss, a cancelled request's) is never published.
      return "#{app.slug} has no client origin (no /build request holds the name), never a client preview" unless client_origin?(app)

      nil
    end

    # Whether a /build request holds APP's name: the claim AppLaunch and
    # AppRequest#queue! make, and the only way a client App row comes to be.
    def self.client_origin?(app)
      AppRequest.holding.exists?(subdomain: app.slug)
    end

    def self.registered_slug?(slug)
      (AppCatalog.apps + AppCatalog.libraries).any? { |entry| entry.slug == slug.to_s }
    end

    # The app's build task (the board task AppLaunch or AppRequest#queue! opened
    # for the request that claimed the subdomain), or nil.
    def self.build_task_slug(app)
      AppRequest.holding.where(subdomain: app.slug).where.not(task_slug: nil).order(id: :desc).pick(:task_slug)
    end

    def initialize(app:, files:, by:, source: "api")
      @app = app
      @files = files
      @by = by.to_s.strip.presence || "unknown"
      @source = source
    end

    def call
      reason = self.class.publishable_reason(@app)
      raise Refused, reason if reason

      bundle = ClientAppBundle.new(@files).validate!
      unready = BundleStore.unready_reason
      raise BundleStore::NotReady, unready if unready

      version = AppPreviewVersion.mint_version
      manifest = bundle.manifest
      manifest.each do |path, meta|
        BundleStore.write(BundleStore.key(@app.slug, version, path), bundle.files.fetch(path), content_type: meta["content_type"])
      end

      flip!(version, manifest, bundle)
    end

    private

    def flip!(version, manifest, bundle)
      url = ClientAppHost.url_for(@app.slug)
      App.transaction do
        @app.lock!
        previous = @app.preview_version
        row = @app.preview_versions.create!(version: version, published_by: @by, file_count: manifest.size,
                                            byte_size: bundle.byte_size, manifest: manifest, published_at: Time.current)
        @app.update!(preview_version: version)
        event = record_event(version, url, row)
        Result.new(app: @app, version: version, previous_version: previous, url: url, event: event, row: row)
      end
    end

    # The status card's signal (task app-card-stage-labels reads it): a
    # checkpoint named `preview_ready` on the app's build task. An app with no
    # build task (an older or hand-made App row) records none.
    def record_event(version, url, row)
      slug = self.class.build_task_slug(@app)
      task = slug && Task.find_by(slug: slug)
      return nil unless task

      task.record_checkpoint_event(
        name: EVENT, status: "ok", actor: @by, source: @source,
        metadata: { "app_slug" => @app.slug, "version" => version, "url" => url,
                    "file_count" => row.file_count, "byte_size" => row.byte_size }
      )
    end
  end
end

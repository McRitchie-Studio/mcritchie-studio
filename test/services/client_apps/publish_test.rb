require "test_helper"
require_relative "../../support/client_bundle_fixtures"

# [unit] ClientApps::Publish: validate, upload under a new version, then flip
# App#preview_version, the history row and the preview_ready event in one
# transaction (docs/agents/system/client-app-host.md).
module ClientApps
  class PublishTest < ActiveSupport::TestCase
    include ClientBundleFixtures

    setup do
      @app = client_app_with_build_task!
      @task = tasks(:new_task)
    end

    def publish(files = bundle_files, by: "pokemon (sess-1)") = Publish.new(app: @app, files: files, by: by).call

    test "[unit] publish uploads every file, flips the version and records the history row" do
      result = publish

      @app.reload
      assert_equal result.version, @app.preview_version
      assert_match AppPreviewVersion::VERSION_FORMAT, result.version
      assert_nil result.previous_version
      row = @app.current_preview
      assert_equal 4, row.file_count
      assert_equal bundle_files.values.sum(&:bytesize), row.byte_size
      assert_equal "pokemon (sess-1)", row.published_by
      assert_equal "text/css; charset=utf-8", row.entry("assets/app-3f9a2c1b.css")["content_type"]
      bundle_files.each do |path, bytes|
        assert_equal bytes, BundleStore.service.download("client-apps/pawsome/#{result.version}/#{path}")
      end
      assert_equal "http://pawsome.localhost:#{ENV['APP_PORT'].presence || ENV['PORT'].presence || '3000'}", result.url
    end

    test "[unit] publish records preview_ready on the app's build task" do
      result = publish

      event = result.event
      assert_equal TaskEvent::CHECKPOINT, event.kind
      assert_equal "preview_ready", event.to_stage
      assert_equal @task.slug, event.task_slug
      assert_equal "ok", event.metadata["status"]
      assert_equal({ "app_slug" => "pawsome", "version" => result.version, "url" => result.url, "file_count" => 4 },
                   event.metadata.slice("app_slug", "version", "url", "file_count"))
      assert_equal "pokemon (sess-1)", event.actor
    end

    test "[unit] a second publish keeps the history and names the previous version" do
      first = publish
      second = publish(bundle_files("extra.txt" => "v2"))

      assert_equal first.version, second.previous_version
      assert_equal second.version, @app.reload.preview_version
      assert_equal [ second.version, first.version ], @app.preview_versions.newest_first.pluck(:version)
      assert_equal 2, @task.task_events.where(to_stage: "preview_ready").count
    end

    test "[unit] an invalid bundle writes nothing" do
      before = Dir.glob(File.join(BundleStore.service.root, "**/*")).size

      assert_raises(ClientAppBundle::Invalid) { publish(bundle_files("server.rb" => "puts 1")) }

      assert_nil @app.reload.preview_version
      assert_equal 0, @app.preview_versions.count
      assert_equal 0, @task.task_events.where(to_stage: "preview_ready").count
      assert_equal before, Dir.glob(File.join(BundleStore.service.root, "**/*")).size
    end

    test "[unit] the flip is atomic: a failure inside it leaves the live version and history unchanged" do
      first = publish

      failing = ->(_app) { raise ActiveRecord::StatementInvalid, "event write failed" }
      Publish.stub(:build_task_slug, failing) do
        assert_raises(ActiveRecord::StatementInvalid) { publish(bundle_files("extra.txt" => "v2")) }
      end

      assert_equal first.version, @app.reload.preview_version
      assert_equal [ first.version ], @app.preview_versions.pluck(:version)
      assert_equal 1, @task.task_events.where(to_stage: "preview_ready").count
    end

    test "[unit] an app with no build task publishes with no event" do
      AppRequest.where(subdomain: "pawsome").update_all(task_slug: nil)

      result = publish

      assert_nil result.event
      assert_equal result.version, @app.reload.preview_version
    end

    test "[unit] a reserved name or a non-label slug is never published" do
      reserved = App.create!(slug: "www", name: "WWW")
      error = assert_raises(Publish::Refused) { Publish.new(app: reserved, files: bundle_files, by: "x").call }
      assert_equal "www is a reserved name (one of ours), never a client preview", error.message
      assert_nil reserved.reload.preview_version

      satellite = apps(:turf_monster)
      error = assert_raises(Publish::Refused) { Publish.new(app: satellite, files: bundle_files, by: "x").call }
      assert_equal "turf-monster is one of ours (config/apps.yml), never a client preview", error.message
      assert_nil satellite.reload.preview_version

      hub = apps(:mcritchie_studio)
      error = assert_raises(Publish::Refused) { Publish.new(app: hub, files: bundle_files, by: "x").call }
      assert_equal "mcritchie-studio is one of ours (config/apps.yml), never a client preview", error.message
      assert_nil hub.reload.preview_version

      odd = App.create!(slug: "x", name: "X")
      assert_raises(Publish::Refused) { Publish.new(app: odd, files: bundle_files, by: "x").call }
    end

    test "[unit] only a client app publishes: an App row no /build request holds is refused" do
      # A valid label on neither deny-list: only the allow-list stops it.
      stray = App.create!(slug: "stray-app", name: "Stray")
      assert_nil AppRequest.reserved_names.find { |name| name == stray.slug }
      assert_not Publish.registered_slug?(stray.slug)
      error = assert_raises(Publish::Refused) { Publish.new(app: stray, files: bundle_files, by: "x").call }
      assert_equal "stray-app has no client origin (no /build request holds the name), never a client preview", error.message
      assert_nil stray.reload.preview_version

      # A cancelled request no longer holds the name.
      request = AppRequest.find_by!(subdomain: @app.slug)
      request.update_columns(status: "cancelled")
      assert_raises(Publish::Refused) { publish }
      assert_nil @app.reload.preview_version

      request.update_columns(status: "live")
      assert publish.version
    end

    test "[unit] the private bucket without keys refuses before any upload" do
      BundleStore.stub(:unready_reason, "keys not set") do
        assert_raises(BundleStore::NotReady) { publish }
      end
      assert_nil @app.reload.preview_version
    end

    test "[unit] the store defaults: private chat bucket in production, Disk elsewhere" do
      assert_equal "test", BundleStore.service_name({})
      assert_equal "other", BundleStore.service_name({ "CLIENT_APP_BUNDLE_SERVICE" => "other" })
      Rails.env.stub(:production?, true) do
        assert_equal "chat_private", BundleStore.service_name({})
        assert_match(/private chat bucket/, BundleStore.unready_reason({}))
        assert_nil BundleStore.unready_reason({ "CHAT_R2_ACCESS_KEY_ID" => "a", "CHAT_R2_SECRET_ACCESS_KEY" => "b", "R2_ENDPOINT" => "c" })
      end
    end

    test "[unit] a read is checked against the manifest's sha256" do
      result = publish
      key = BundleStore.key("pawsome", result.version, "app.js")
      BundleStore.clear_cache!

      assert_equal "console.log('hi')", BundleStore.read(key, sha256: Digest::SHA256.hexdigest("console.log('hi')"))
      assert_raises(BundleStore::Corrupt) { BundleStore.read(key, sha256: "0" * 64) }
    end
  end
end

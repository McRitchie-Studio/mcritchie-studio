module Api
  module V1
    # Publish a client app's static bundle to the shared host
    # (docs/agents/system/client-app-host.md; bin/client-bundle publish).
    #
    #   POST /api/v1/client_bundles/:sub
    #   { "files": [ { "path": "index.html", "content_base64": "…" }, … ] }
    #
    #   201 { data: { app_slug, version, previous_version, url, file_count,
    #                 byte_size, event: { task_slug, name, id } | null } }
    #   422 BUNDLE_INVALID (with `errors`) · 403 SESSION_FORBIDDEN · 404 NOT_FOUND
    #   413 TOO_LARGE · 411 LENGTH_REQUIRED · 503 STORAGE_NOT_READY
    #
    # WHO. An agent session only: the shared token answers 401 and a client or
    # harness session 403. An admin session publishes any client app; a studio
    # session publishes only the app whose BUILD TASK it is scoped to (the
    # launcher's builder holds that task's session).
    class ClientBundlesController < BaseController
      # Base64 grows a body by 4/3; this admits the largest valid bundle with room
      # for the JSON around it, and refuses anything bigger before it is parsed.
      MAX_REQUEST_BYTES = (ClientAppBundle::MAX_BYTES * 4 / 3) + (1024 * 1024)

      wrap_parameters false

      before_action :require_body_size!
      before_action :require_agent_session!
      before_action :set_app
      before_action :require_publisher!

      def create
        # A refusal (a bad bundle, a reserved name) is the caller's to fix, not an
        # error to log, so both are checked before the logged write.
        files = decoded_files
        ClientAppBundle.new(files).validate!
        reason = ClientApps::Publish.publishable_reason(@app)
        raise ClientApps::Publish::Refused, reason if reason

        result = rescue_and_log(target: @app) do
          ClientApps::Publish.new(app: @app, files: files, by: publisher_name, source: "api").call
        end
        render_data(result_json(result), status: :created)
      rescue ClientAppBundle::Invalid => e
        render json: { error: "bundle refused", error_code: "BUNDLE_INVALID", errors: e.errors }, status: :unprocessable_entity
      rescue ClientApps::Publish::Refused => e
        render_error(e.message, status: :unprocessable_entity, error_code: "NOT_PUBLISHABLE")
      rescue ClientApps::BundleStore::NotReady => e
        render_error(e.message, status: :service_unavailable, error_code: "STORAGE_NOT_READY")
      end

      private

      def require_body_size!
        length = request.content_length
        return render_error("send a Content-Length", status: :length_required, error_code: "LENGTH_REQUIRED") if length.nil?
        return if length <= MAX_REQUEST_BYTES

        render_error("the request is #{length} bytes, over #{MAX_REQUEST_BYTES}", status: :content_too_large, error_code: "TOO_LARGE")
      end

      def require_agent_session!
        session = current_agent_session
        return render_session_refusal("a client session publishes no bundle") if session&.client?
        return if session

        render_error("publishing a bundle needs an agent session; the shared token carries none",
                     status: :unauthorized, error_code: "SESSION_REQUIRED")
      end

      def set_app
        @app = App.find_by!(slug: params[:sub].to_s)
      end

      def require_publisher!
        session = current_agent_session
        return if session.admin?

        task_slug = ClientApps::Publish.build_task_slug(@app)
        return if task_slug && session.covers_task?(task_slug)

        render_session_refusal("agent session #{session.slug} may publish only the app whose build task it holds" \
                               "#{task_slug ? " (#{@app.slug}'s is #{task_slug})" : "; #{@app.slug} has no build task, so an admin session publishes it"}")
      end

      def publisher_name
        session = current_agent_session
        "#{session.soul} (#{session.slug})"
      end

      # { path => bytes } from the body's `files`. A malformed entry raises
      # ClientAppBundle::Invalid, so it answers as a refused bundle.
      def decoded_files
        body = JSON.parse(request.raw_post)
        files = body.is_a?(Hash) ? body["files"] : nil
        raise ClientAppBundle::Invalid, "files must be a list of { path, content_base64 }" unless files.is_a?(Array)
        raise ClientAppBundle::Invalid, "the bundle has more than #{ClientAppBundle::MAX_FILES} files" if files.size > ClientAppBundle::MAX_FILES

        files.each_with_object({}) do |entry, out|
          path = entry.is_a?(Hash) ? entry["path"] : nil
          data = entry.is_a?(Hash) ? entry["content_base64"] : nil
          raise ClientAppBundle::Invalid, "each file needs a path and content_base64" unless path.is_a?(String) && data.is_a?(String)
          raise ClientAppBundle::Invalid, "a path appears twice" if out.key?(path)

          out[path] = Base64.strict_decode64(data)
        rescue ArgumentError
          raise ClientAppBundle::Invalid, "a file's content_base64 is not base64"
        end
      rescue JSON::ParserError
        raise ClientAppBundle::Invalid, "the body is not JSON"
      end

      def result_json(result)
        event = result.event
        { app_slug: result.app.slug, version: result.version, previous_version: result.previous_version, url: result.url,
          file_count: result.row.file_count, byte_size: result.row.byte_size,
          event: event && { task_slug: event.task_slug, name: event.to_stage, id: event.id } }
      end
    end
  end
end

require "openssl"

module Api
  module V1
    # Receiver for GitHub Actions webhook deliveries (DevOps v2 — agents read CI
    # status off the board instead of polling `gh`).
    #
    # GitHub calls this endpoint, NOT an agent, so it is EXEMPT from the api/v1
    # bearer-token auth (skip_before_action below) — its ONLY gate is the HMAC
    # signature in X-Hub-Signature-256. There is no CSRF token to skip: the api
    # namespace is ActionController::API, which carries no forgery protection.
    #
    # Keep the controller dumb: verify the signature, hand the parsed event to a
    # job, and ACK fast (GitHub's delivery times out at ~10s). All ingest logic
    # — the idempotent, monotonic upsert — lives in GithubWorkflowRunIngestJob.
    class GithubWebhooksController < BaseController
      skip_before_action :authenticate_api!

      def create
        return head :unauthorized unless valid_signature?

        event = request.headers["X-GitHub-Event"].to_s

        # GitHub's connectivity probe — verify + 200, nothing to ingest.
        return head :ok if event == "ping"

        payload = JSON.parse(raw_body)
        GithubWorkflowRunIngestJob.perform_later(event, payload)
        head :ok
      rescue JSON::ParserError => e
        # Body was signed by GitHub but not valid JSON — log and ACK anyway; a
        # redelivery of the same malformed body would only loop.
        ErrorLog.capture!(e)
        head :ok
      end

      private

      # Constant-time compare of "sha256=" + HMAC-SHA256(raw_body, secret) against
      # the delivered signature. Missing signature or secret, or any mismatch,
      # fails closed.
      def valid_signature?
        signature = request.headers["X-Hub-Signature-256"].to_s
        return false if signature.blank? || webhook_secret.blank?

        expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, raw_body)
        ActiveSupport::SecurityUtils.secure_compare(signature, expected)
      end

      # The exact bytes GitHub signed. request.raw_post reads and rewinds the
      # rack input and caches it, so param parsing and this reader agree.
      def raw_body
        request.raw_post
      end

      # Ops-provided config var (the orchestrator sets GITHUB_WEBHOOK_SECRET on
      # Heroku), with a credentials fallback to match the app's secret convention.
      def webhook_secret
        ENV["GITHUB_WEBHOOK_SECRET"].presence || Rails.application.credentials.github_webhook_secret
      end
    end
  end
end

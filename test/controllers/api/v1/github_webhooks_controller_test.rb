require "test_helper"

module Api
  module V1
    # [integration] The GitHub Actions webhook receiver. Its ONLY gate is the
    # HMAC signature — no bearer token (GitHub calls it, not an agent). Valid
    # delivery verifies fast and hands off to the ingest job; a bad or missing
    # signature is rejected 401 with nothing enqueued.
    class GithubWebhooksControllerTest < ActionDispatch::IntegrationTest
      SECRET = "test-webhook-secret-do-not-use-in-prod"

      setup do
        @prev_secret = ENV["GITHUB_WEBHOOK_SECRET"]
        ENV["GITHUB_WEBHOOK_SECRET"] = SECRET
        @body = file_fixture("github_workflow_run_event.json").read
      end

      teardown do
        if @prev_secret.nil?
          ENV.delete("GITHUB_WEBHOOK_SECRET")
        else
          ENV["GITHUB_WEBHOOK_SECRET"] = @prev_secret
        end
      end

      # Sign a raw body the way GitHub does: sha256= + HMAC-SHA256(body, secret).
      def sign(body, secret = SECRET)
        "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      end

      def post_webhook(body:, event: "workflow_run", signature: :valid, headers: {})
        signature = sign(body) if signature == :valid
        base = { "Content-Type" => "application/json", "X-GitHub-Event" => event }
        base["X-Hub-Signature-256"] = signature if signature
        post "/api/v1/github/webhook", params: body, headers: base.merge(headers)
      end

      test "[integration] valid signature enqueues the ingest job and returns 200" do
        assert_enqueued_with(job: GithubWorkflowRunIngestJob) do
          post_webhook(body: @body)
        end
        assert_response :ok
      end

      test "[integration] a wrong-secret signature is rejected 401 with no job" do
        assert_no_enqueued_jobs do
          post_webhook(body: @body, signature: sign(@body, "the-wrong-secret"))
        end
        assert_response :unauthorized
      end

      test "[integration] a missing signature is rejected 401 with no job" do
        assert_no_enqueued_jobs do
          post_webhook(body: @body, signature: nil)
        end
        assert_response :unauthorized
      end

      test "[integration] a tampered body (signature no longer matches) is 401" do
        good_sig = sign(@body)
        tampered = @body.sub("success", "failure")
        assert_no_enqueued_jobs do
          post_webhook(body: tampered, signature: good_sig)
        end
        assert_response :unauthorized
      end

      test "[integration] ping event verifies and returns 200 without enqueuing" do
        ping = { "zen" => "Non-blocking is better than blocking.", "hook_id" => 1 }.to_json
        assert_no_enqueued_jobs do
          post_webhook(body: ping, event: "ping", signature: sign(ping))
        end
        assert_response :ok
      end

      test "[integration] endpoint skips bearer auth — no Authorization header needed" do
        # No Authorization header at all; the signature is the sole gate.
        post_webhook(body: @body)
        assert_response :ok
      end

      test "[integration] enqueues with the event name and the parsed payload" do
        assert_enqueued_with(
          job: GithubWorkflowRunIngestJob,
          args: ["workflow_run", JSON.parse(@body)]
        ) do
          post_webhook(body: @body)
        end
      end

      test "[integration] a deployment_review delivery enqueues the ingest job under its event name" do
        review = file_fixture("github_deployment_review_event.json").read
        assert_enqueued_with(
          job: GithubWorkflowRunIngestJob,
          args: ["deployment_review", JSON.parse(review)]
        ) do
          post_webhook(body: review, event: "deployment_review", signature: sign(review))
        end
        assert_response :ok
      end

      test "[integration] a deployment_protection_rule delivery is verified and enqueued" do
        review = file_fixture("github_deployment_review_event.json").read
        assert_enqueued_with(job: GithubWorkflowRunIngestJob) do
          post_webhook(body: review, event: "deployment_protection_rule", signature: sign(review))
        end
        assert_response :ok
      end
    end
  end
end

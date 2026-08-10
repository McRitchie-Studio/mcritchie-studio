require "test_helper"

module Api
  module V1
    class TriageFindingsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
        }
      end

      test "[integration] create files an open finding" do
        assert_difference "TriageFinding.count", 1 do
          post api_v1_triage_findings_path,
               params: { title: "Navbar offset drifts on sticky consumers",
                         body: "Two engine consumers offset from --nav-h where they want --nav-bottom.",
                         source: "carl", repo: "studio-engine" },
               headers: @headers, as: :json
        end

        assert_response :created
        finding = TriageFinding.order(:created_at).last
        assert_equal "open", finding.status
        assert_equal "carl", finding.source
        assert_equal "studio-engine", finding.repo
      end

      test "[integration] index filters by status" do
        open_finding = TriageFinding.create!(title: "An open finding")
        dismissed = TriageFinding.create!(title: "A dismissed finding")
        dismissed.dismiss!

        get api_v1_triage_findings_path(status: "open"), headers: @headers
        assert_response :success
        slugs = response.parsed_body["data"].map { |f| f["slug"] }
        assert_includes slugs, open_finding.slug
        refute_includes slugs, dismissed.slug
      end

      test "[integration] create without a title is rejected" do
        post api_v1_triage_findings_path, params: { body: "no title" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
      end

      test "[integration] unauthenticated requests are refused" do
        post api_v1_triage_findings_path, params: { title: "No bearer" }, as: :json
        assert_response :unauthorized
      end
    end
  end
end

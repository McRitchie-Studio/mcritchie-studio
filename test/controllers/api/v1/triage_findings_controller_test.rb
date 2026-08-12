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

      # A finding filed over the bearer lane with no prior-art claim is stored as
      # "unknown" — the state that says NOBODY LOOKED. Never nil, never "none".
      test "[integration] create defaults prior art to unknown rather than blank" do
        post api_v1_triage_findings_path,
             params: { title: "Preview iframe has no sandbox" }, headers: @headers, as: :json

        assert_response :created
        assert_equal "unknown", response.parsed_body.dig("data", "prior_art")
        assert_equal "unknown", TriageFinding.order(:created_at).last.prior_art
      end

      test "[integration] create records an investigated prior-art claim with its evidence" do
        note = "TM's deleted preview view carried the identical iframe since 2025-11"
        post api_v1_triage_findings_path,
             params: { title: "Preview iframe has no sandbox", prior_art: "found", prior_art_note: note },
             headers: @headers, as: :json

        assert_response :created
        finding = TriageFinding.order(:created_at).last
        assert_equal "found", finding.prior_art
        assert_equal note, finding.prior_art_note
      end

      # Fail closed. A prior-art value the board cannot parse must not be coerced
      # into a friendlier state — that would be the board inventing the claim.
      test "[integration] create refuses an out-of-range prior-art state" do
        assert_no_difference "TriageFinding.count" do
          post api_v1_triage_findings_path,
               params: { title: "Bad state", prior_art: "probably-fine" }, headers: @headers, as: :json
        end
        assert_response :unprocessable_entity
      end

      test "[integration] create refuses a found claim with no evidence" do
        assert_no_difference "TriageFinding.count" do
          post api_v1_triage_findings_path,
               params: { title: "Claims a check it cannot show", prior_art: "found" },
               headers: @headers, as: :json
        end
        assert_response :unprocessable_entity
      end

      # The bearer lane stays file + list ONLY. Widening it is not a side effect
      # this change (or any other) gets to have quietly.
      test "[integration] the bearer lane still exposes no promote or dismiss route" do
        assert_raises(NoMethodError) { api_v1_promote_triage_finding_path("finding-x") }
        assert_raises(NoMethodError) { api_v1_dismiss_triage_finding_path("finding-x") }
      end

      test "[integration] index carries prior art so a reader never has to infer it" do
        finding = TriageFinding.create!(title: "Unchecked surface")

        get api_v1_triage_findings_path(status: "open"), headers: @headers
        assert_response :success
        row = response.parsed_body["data"].find { |f| f["slug"] == finding.slug }
        assert_equal "unknown", row["prior_art"]
      end
    end
  end
end

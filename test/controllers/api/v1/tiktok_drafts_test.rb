require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require_relative "../../../support/tiktok_draft_fakes"

module Api
  module V1
    # [integration] The tiktok-draft SOP's chat door as bin/tiktok-draft drives
    # it: a clip by its slug, the preview, a dry run that writes nothing, a
    # draft that records the attempt and (once the job runs) uploads to the
    # inbox and records TikTok's publish id, the refresh, and the probe's
    # refusal on a server with no TikTok keys. TikTok, R2 and ESPN are fakes.
    class TiktokDraftsTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      setup do
        @video = TiledVideo.seed!
        person = Person.create!(athlete: true, first_name: "Test", last_name: "Tiktok Epsilon")
        look = person.appearances.live.create!(descriptor: "Home", team_slug: "buffalo-bills")
        @video.video_performers.find_by!(ordinal: 1).update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
        @alt = AltVideo.build_from!(@video.reload)
        @clip = @alt.clips.first
        TiledVideo.version!(@clip, number: 1)
        @uploader = TiktokDraftFakes::Uploader.new
        Tiktok::DraftClip.uploader = @uploader
        Tiktok::DraftClip.reader = TiktokDraftFakes::Reader.new
        Tiktok::DraftClip.fetch = TiktokDraftFakes.espn
      end

      teardown { Tiktok::DraftClip.uploader = Tiktok::DraftClip.reader = Tiktok::DraftClip.fetch = nil }

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}" }
      end

      # The shared secret's token: a valid bearer that carries no session.
      def shared_headers = auth_headers

      def session_headers(session) = { "Authorization" => "Bearer #{session.token}" }

      def admin_headers
        session_headers(AgentSession.create!(soul: "xan", tier: "admin", issued_by: "operator_grant"))
      end

      def data = JSON.parse(response.body).fetch("data")

      def path(clip = @clip) = api_v1_alt_video_clip_tiktok_drafts_path(clip.slug)

      test "the index answers the clip, what a draft would send, and no attempts" do
        get path, headers: auth_headers

        assert_response :success
        assert_equal [@clip.slug, 1, true], data["clip"].values_at("slug", "primary_version", "available")
        assert_equal ["Bills 3-2 #nfl #nfltiktok #footballtiktok #bills #fyp", "Test Tiktok Epsilon", "the clip's target", "Buffalo Bills", "look"],
                     data["preview"].values_at("caption", "athlete", "athlete_rule", "team", "team_from")
        assert_equal data.dig("preview", "caption").length, data.dig("preview", "caption_length")
        assert_empty data["attempts"]
      end

      test "a dry run answers the preview and records nothing" do
        assert_no_enqueued_jobs { post path, params: { dry_run: true }, headers: auth_headers, as: :json }

        assert_response :success
        assert_equal true, data["dry_run"]
        assert_match(/\ABills 3-2 /, data.dig("preview", "caption"))
        assert_equal 0, TiktokDraft.count
        assert_empty @uploader.uploads
      end

      test "a draft records the attempt, uploads to the inbox and records TikTok's publish id" do
        assert_enqueued_jobs(1, only: TiktokDraftJob) { post path, headers: admin_headers, as: :json }

        assert_response :created
        assert_equal ["queued", 1, "xan via bin/tiktok-draft"], data.values_at("state", "version_number", "requested_by")
        perform_enqueued_jobs

        get path, headers: auth_headers
        attempt = data["attempts"].sole
        assert_equal ["delivered", "SEND_TO_USER_INBOX", "v_inbox_file~synthetic.1", "Sent to your TikTok inbox"],
                     attempt.values_at("state", "tiktok_status", "publish_id", "state_label")
        assert_equal TiktokDraft::NEXT_STEPS, attempt["next_steps"]
        assert_equal 1, @uploader.uploads.size
      end

      test "a clip that cannot be drafted answers 409 with the reason" do
        post path(@alt.clips.second), headers: admin_headers, as: :json

        assert_response :conflict
        body = JSON.parse(response.body)
        assert_equal "NOT_DRAFTABLE", body["error_code"]
        assert_match(/no generated version yet/, body["error"])
        assert_equal 0, TiktokDraft.count

        get path(@alt.clips.second), headers: auth_headers
        assert_match(/no generated version yet/, data.dig("preview", "refused"))
      end

      test "refresh reads TikTok once more for a processing attempt" do
        draft = TiktokDraft.create!(clip: @clip, version_number: 1, version_object_key: "k", caption: "c", state: "processing", publish_id: "p1")
        post refresh_api_v1_tiktok_draft_path(draft), headers: auth_headers, as: :json

        assert_response :success
        assert_equal "delivered", data["state"]
      end

      test "the probe says the keys are missing on a server without them, and names no secret" do
        get api_v1_tiktok_creator_info_path, headers: auth_headers

        assert_response :service_unavailable
        body = JSON.parse(response.body)
        assert_equal "NOT_CONFIGURED", body["error_code"]
        assert_match(/TIKTOK_CLIENT_KEY/, body["error"])
      end

      test "an unknown slug is a 404 and no token is a 401" do
        get api_v1_alt_video_clip_tiktok_drafts_path("no-such-clip"), headers: auth_headers
        assert_response :not_found

        post path, as: :json
        assert_response :unauthorized
        assert_equal 0, TiktokDraft.count
      end

      # ── Hardening (piece 22) ─────────────────────────────────────────────────

      def refused_for_want_of_an_admin_session
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "SESSION_FORBIDDEN", body["error_code"]
        assert_match(/needs an admin session/, body["error"])
        assert_match(/agent_sessions:grant_admin/, body["error"], "the refusal says how to get one")
        assert_match(/AGENT_ADMIN_SESSION_TOKEN/, body["error"], "and where bin/tiktok-draft reads it")
        assert_equal 0, TiktokDraft.count
        body
      end

      test "the shared token, which carries no session, cannot create a draft" do
        assert_no_enqueued_jobs { post path, headers: shared_headers, as: :json }

        assert_match(/the shared token carries no session/, refused_for_want_of_an_admin_session["error"])
      end

      test "an agent bearer without an admin session is refused on draft create" do
        task = Task.create!(title: "Synthetic Build Task", slug: "synthetic-build", stage: "building",
                            metadata: { "devops" => { "built_by" => "pokemon" } })
        studio = AgentSession.issue_studio!(soul: "pokemon", task:, issued_by: "task_claim")
        assert_no_enqueued_jobs { post path, headers: session_headers(studio), as: :json }

        assert_match(/pokemon holds a studio session/, refused_for_want_of_an_admin_session["error"])
      end

      test "an admin session creates the draft; a revoked one is a 401" do
        session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        assert_enqueued_jobs(1, only: TiktokDraftJob) { post path, headers: session_headers(session), as: :json }
        assert_response :created

        TiktokDraft.update_all(state: "failed")
        session.revoke!(by: "test")
        assert_no_enqueued_jobs { post path, headers: session_headers(session), as: :json }
        assert_response :unauthorized
        assert_equal 1, TiktokDraft.count
      end

      test "reading stays open to the shared token: the index, a dry run and a refresh" do
        get path, headers: shared_headers
        assert_response :success

        post path, params: { dry_run: true }, headers: shared_headers, as: :json
        assert_response :success
        assert_equal true, data["dry_run"]

        draft = TiktokDraft.create!(clip: @clip, version_number: 1, version_object_key: "k", caption: "c", state: "unknown", publish_id: "p1")
        post refresh_api_v1_tiktok_draft_path(draft), headers: shared_headers, as: :json
        assert_response :success
        assert_equal "delivered", data["state"]
      end

      test "a request is a dry run that writes nothing or a gated draft, never between" do
        %w[false 0 off].each do |spelling|
          post path, params: { dry_run: spelling }, headers: shared_headers, as: :json
          refused_for_want_of_an_admin_session
        end

        %w[true 1 yes anything].each do |spelling|
          assert_no_enqueued_jobs { post path, params: { dry_run: spelling }, headers: shared_headers, as: :json }
          assert_response :success
          assert_equal true, data["dry_run"]
          assert_equal 0, TiktokDraft.count
        end
      end

      test "the admin gate answers before the clip is looked up" do
        post api_v1_alt_video_clip_tiktok_drafts_path("no-such-clip"), headers: shared_headers, as: :json
        assert_response :forbidden
      end

      [OpenSSL::SSL::SSLError.new("SSL_connect returned=1"), EOFError.new("end of file reached"), Net::OpenTimeout.new].each do |boom|
        test "ESPN down with #{boom.class} answers 409, not a 500, and records nothing" do
          Tiktok::DraftClip.fetch = ->(_url) { raise boom }
          assert_no_enqueued_jobs { post path, headers: admin_headers, as: :json }

          assert_response :conflict
          body = JSON.parse(response.body)
          assert_equal "NOT_DRAFTABLE", body["error_code"]
          assert_match(/could not read ESPN/, body["error"])
          assert_equal 0, TiktokDraft.count

          post path, params: { dry_run: true }, headers: shared_headers, as: :json
          assert_response :conflict

          get path, headers: shared_headers
          assert_response :success
          assert_match(/could not read ESPN/, data.dig("preview", "refused"))
        end
      end

      test "a second request that lands while the first reads ESPN answers 409 and leaves one draft" do
        espn = TiktokDraftFakes.espn
        landed = false
        Tiktok::DraftClip.fetch = lambda do |url|
          unless landed
            landed = true
            TiktokDraft.create!(clip: @clip, version_number: 1, version_object_key: "k1", caption: "the other request", state: "queued")
          end
          espn.call(url)
        end
        errors = ErrorLog.count
        assert_no_enqueued_jobs { post path, headers: admin_headers, as: :json }

        assert_response :conflict
        assert_equal "NOT_DRAFTABLE", JSON.parse(response.body)["error_code"]
        assert_equal ["the other request"], TiktokDraft.pluck(:caption)
        assert_equal errors, ErrorLog.count, "a refusal is an answer, not an ErrorLog"
      end
    end
  end
end

require "test_helper"

module Api
  module V1
    # [integration] /api/v1/facts: an agent session reads and writes facts at its
    # tier, and every refusal answers 4xx with the reason.
    class FactsControllerTest < ActionDispatch::IntegrationTest
      ORDINARY = "prefers-the-east-gate-41c9".freeze
      SENSITIVE = "salary-band-seven-9d2e".freeze

      setup do
        @admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        task = tasks(:new_task)
        task.update_columns(stage: "building")
        @studio = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")
        @person = people(:josh_allen)
        @ordinary = record(key: "gate", value: ORDINARY)
        @sensitive = record(key: "salary", value: SENSITIVE, sensitivity: "sensitive")
      end

      def record(**attrs)
        Fact.create!({ subject_type: "person", subject_slug: @person.slug, source_kind: "knowledge_doc",
                       source_ref: "doc-1", recorded_by_session_slug: @admin.slug }.merge(attrs))
      end

      def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
      def body = JSON.parse(response.body)
      def legacy = { "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}" }

      def list(session, **params)
        get api_v1_facts_path, params: { subject_type: "person", subject_slug: @person.slug }.merge(params), headers: bearer(session)
      end

      def create(session, **fact)
        post api_v1_facts_path, headers: bearer(session), as: :json,
                                params: { fact: { subject_type: "person", subject_slug: @person.slug, source_ref: "doc-2" }.merge(fact) }
      end

      test "[integration] studio_reads_ordinary_only" do
        list(@studio)

        assert_response :success
        assert_equal [@ordinary.slug], body["data"].map { |f| f["slug"] }
        assert_equal ORDINARY, body["data"].first["value"]
        assert_not_includes response.body, SENSITIVE
      end

      test "[integration] admin_reads_sensitive" do
        list(@admin)

        assert_response :success
        assert_equal [@ordinary.slug, @sensitive.slug].sort, body["data"].map { |f| f["slug"] }.sort
        assert_includes response.body, SENSITIVE
        fact = body["data"].find { |f| f["slug"] == @sensitive.slug }
        assert_equal({ "kind" => "knowledge_doc", "ref" => "doc-1", "note" => nil }, fact["source"])
        assert_equal "steffon", fact["recorded_by"]
      end

      test "[integration] legacy_token_401" do
        get api_v1_facts_path, params: { subject_type: "person", subject_slug: @person.slug }, headers: legacy

        assert_response :unauthorized
        assert_equal "SESSION_REQUIRED", body["error_code"]
        assert_match(/agent session/, body["error"])
        assert_not_includes response.body, ORDINARY

        post api_v1_facts_path, headers: legacy, as: :json, params: { fact: { key: "x", value: "y" } }
        assert_response :unauthorized
      end

      test "[integration] the legacy token still reaches another endpoint (control)" do
        get api_v1_agent_path("no-such-agent-facts-probe"), headers: legacy

        assert_response :not_found
      end

      test "[integration] client_403" do
        client = AgentSession.create!(soul: "tyrion", tier: "client", issued_by: "runtime_key")

        list(client)

        assert_response :forbidden
        assert body["error"].present?
        assert_not_includes response.body, ORDINARY
      end

      test "[integration] a list needs its subject" do
        get api_v1_facts_path, headers: bearer(@admin)

        assert_response :unprocessable_entity
        assert_equal "SUBJECT_REQUIRED", body["error_code"]
      end

      test "[integration] a write records the session, its soul and the source" do
        assert_difference -> { Fact.count }, 1 do
          create(@studio, key: "hometown", value: "Firebaugh, California", source_kind: "drive_file", source_note: "page 2")
        end

        assert_response :created
        fact = Fact.find_by!(slug: body.dig("data", "slug"))
        assert_equal @studio.slug, fact.recorded_by_session_slug
        assert_equal "pokemon", body.dig("data", "recorded_by")
        assert_equal %w[ordinary drive_file doc-2 page\ 2], [fact.sensitivity, fact.source_kind, fact.source_ref, fact.source_note]
      end

      test "[integration] an identity-class value answers 422 with the pointer message and stores nothing" do
        assert_no_difference -> { Fact.count } do
          create(@admin, key: "note", value: "SSN 123-45-6789")
        end

        assert_response :unprocessable_entity
        assert_equal "IDENTITY_REFUSED", body["error_code"]
        assert_match(/store a pointer to the original/, body["error"])
        assert_not_includes response.body, "123-45-6789"
      end

      test "[integration] a pointer is stored for an identity-class key" do
        create(@admin, key: "ssn", source_kind: "drive_file", source_ref: "1AbC")

        assert_response :created
        assert_equal [true, nil], [body.dig("data", "pointer"), body.dig("data", "value")]
      end

      test "[integration] a studio session writes ordinary facts only; admin writes sensitive" do
        assert_no_difference -> { Fact.count } do
          create(@studio, key: "band", value: "seven", sensitivity: "sensitive")
        end
        assert_response :forbidden
        assert_match(/admin/, body["error"])

        create(@admin, key: "band", value: "seven", sensitivity: "sensitive")
        assert_response :created
      end

      test "[integration] supersede_keeps_predecessor_and_source" do
        post supersede_api_v1_fact_path(@ordinary.slug), headers: bearer(@studio), as: :json,
                                                         params: { fact: { value: "prefers the west gate", source_ref: "doc-9" } }

        assert_response :created
        successor = Fact.find_by!(slug: body.dig("data", "slug"))
        @ordinary.reload
        assert_equal successor.slug, @ordinary.superseded_by_slug
        assert_equal [ORDINARY, "doc-1"], [@ordinary.value, @ordinary.source_ref]
        assert_equal ["gate", "doc-9", @studio.slug], [successor.key, successor.source_ref, successor.recorded_by_session_slug]

        list(@studio)
        assert_equal [successor.slug], body["data"].map { |f| f["slug"] }
        list(@studio, history: 1)
        assert_equal [successor.slug, @ordinary.slug].sort, body["data"].map { |f| f["slug"] }.sort
      end

      test "[integration] a studio session cannot supersede or retire a sensitive fact" do
        post supersede_api_v1_fact_path(@sensitive.slug), headers: bearer(@studio), as: :json,
                                                          params: { fact: { value: "x", source_ref: "d" } }
        assert_response :forbidden
        post retire_api_v1_fact_path(@sensitive.slug), headers: bearer(@studio)
        assert_response :forbidden
        assert @sensitive.reload.current?
      end

      test "[integration] retire ends a fact, and a second retire answers 422" do
        post retire_api_v1_fact_path(@ordinary.slug), headers: bearer(@studio)
        assert_response :success
        assert @ordinary.reload.retired?

        post retire_api_v1_fact_path(@ordinary.slug), headers: bearer(@studio)
        assert_response :unprocessable_entity
        assert_match(/retired/, body["error"])

        post retire_api_v1_fact_path("fact-nope"), headers: bearer(@admin)
        assert_response :not_found
      end

      test "[integration] no fact value reaches the log, nested or at the top level" do
        nested = "logged-nested-value-5b1f"
        top = "logged-top-level-value-8e7a"
        log = StringIO.new
        logger = ActiveSupport::Logger.new(log)
        logger.level = :debug
        with_loggers(logger) do
          create(@admin, key: "nested", value: nested)
          post api_v1_facts_path, headers: bearer(@admin), as: :json,
                                  params: { subject_type: "person", subject_slug: @person.slug, key: "top", value: top, source_ref: "d" }
          list(@admin)
        end

        assert_equal 2, Fact.where(key: %w[nested top]).count, "both writes landed"
        assert_includes log.string, "Parameters", "the request log was captured (control)"
        [nested, top, ORDINARY, SENSITIVE].each { |value| assert_not_includes log.string, value }
      end

      test "[integration] without encryption keys every facts call answers 503 with the ENV names" do
        Fact.stub(:encryption_ready?, false) do
          list(@admin)
        end

        assert_response :service_unavailable
        assert_match(/ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY/, body["error"])
      end

      private

      def with_loggers(logger)
        previous = [Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger]
        Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
        yield
      ensure
        Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = previous
      end
    end
  end
end

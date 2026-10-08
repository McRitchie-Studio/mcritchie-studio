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

      BANK = "000123456789".freeze
      SSN = "123-45-6789".freeze

      def flat(session, **fact)
        post api_v1_facts_path, headers: bearer(session), as: :json,
                                params: { subject_type: "person", subject_slug: @person.slug, source_ref: "doc-2" }.merge(fact)
      end

      # Both body shapes answer the pointer refusal, store nothing and repeat no data.
      def assert_identity_refused(label, *data, **fact)
        %i[create flat].each do |shape|
          assert_no_difference -> { Fact.count }, "#{label} (#{shape}) stored a fact" do
            send(shape, @admin, **fact)
          end
          assert_response :unprocessable_entity, "#{label} (#{shape})"
          assert_equal "IDENTITY_REFUSED", body["error_code"], "#{label} (#{shape})"
          assert_match(/store a pointer to the original/, body["error"], "#{label} (#{shape})")
          data.each { |text| assert_not_includes response.body, text, "#{label} (#{shape}) repeats the data" }
        end
      end

      test "[integration] bank_account=digits answers 422 with the pointer message, nested and flat" do
        assert_identity_refused("bank_account", BANK, key: "bank_account", value: BANK)
        assert_identity_refused("checking-account", BANK, key: "checking-account", value: BANK)
        assert_identity_refused("a long number under an ordinary key", BANK, key: "note", value: BANK)
        assert_identity_refused("a JSON number", BANK.to_i.to_s, key: "note", value: BANK.to_i)
        assert_identity_refused("a JSON number under an identity key", key: "card", value: 4321)

        %i[create flat].each do |shape|
          send(shape, @admin, key: "bank-#{shape}", value: "First National")
          assert_response :created, "an ordinary key and value saves (control, #{shape})"
          send(shape, @admin, key: "account-#{shape}", source_kind: "drive_file", source_ref: "1AbC")
          assert_response :created, "the pointer saves (control, #{shape})"
          assert_equal [true, nil], [body.dig("data", "pointer"), body.dig("data", "value")]
        end
      end

      test "[integration] 'ssn: digits' sent as the key answers 422 with the pointer message, nested and flat" do
        assert_identity_refused("a colon for the equals sign", SSN, key: "ssn: #{SSN}")
        assert_identity_refused("the same with a value", SSN, key: "ssn: #{SSN}", value: "on file")
        assert_identity_refused("digits joined to the key", SSN, key: "ssn-#{SSN}")
        assert_identity_refused("a JSON number as the key", key: BANK.to_i)
        assert_identity_refused("the reference", SSN, key: "note", value: "x", source_ref: "ssn #{SSN}")
        assert_identity_refused("the note", BANK, key: "note", value: "x", source_note: "wire #{BANK}")
        assert_equal 0, Fact.where("key LIKE ?", "%6789%").count

        create(@admin, key: "ssn", source_kind: "drive_file", source_ref: "1AbC")
        assert_response :created, "the pointer the message names saves (control)"
      end

      test "[integration] a key that is not a name, or a value that is not a scalar, answers 422 and stores nothing" do
        { "a spaced key" => { key: "home town", value: "Firebaugh" }, "an upper-case key" => { key: "Hometown", value: "Firebaugh" },
          "an array value" => { key: "note", value: [BANK] }, "a hash value" => { key: "note", value: { number: BANK } },
          "an array key" => { key: ["ssn", SSN], value: "x" } }.each do |label, fact|
          %i[create flat].each do |shape|
            assert_no_difference -> { Fact.count }, label do
              send(shape, @admin, **fact)
            end
            assert_response :unprocessable_entity, "#{label} (#{shape})"
            assert_not_includes response.body, BANK
          end
        end

        create(@admin, key: "hometown", value: "Firebaugh")
        assert_response :created
      end

      test "[integration] a supersede passes the same refusal and leaves the predecessor current" do
        pointer = record(key: "bank-account", value: nil, source_kind: "drive_file", source_ref: "drive-1")
        { "a long number" => [@ordinary, { value: BANK }], "an ssn" => [@ordinary, { value: "his SSN is #{SSN}" }],
          "a JSON number" => [@ordinary, { value: BANK.to_i }], "a note" => [@ordinary, { value: "x", source_note: "acct #{BANK}" }],
          "a reference" => [@ordinary, { value: "x", source_ref: BANK }],
          "a value for a pointer" => [pointer, { value: "First National" }] }.each do |label, (fact, attrs)|
          [{ fact: { source_ref: "doc-9" }.merge(attrs) }, { source_ref: "doc-9" }.merge(attrs)].each do |params|
            assert_no_difference -> { Fact.count }, label do
              post supersede_api_v1_fact_path(fact.slug), headers: bearer(@admin), as: :json, params: params
            end
            assert_response :unprocessable_entity, label
            assert_equal "IDENTITY_REFUSED", body["error_code"], label
            [BANK, SSN].each { |text| assert_not_includes response.body, text, label }
            assert fact.reload.current?, label
          end
        end

        post supersede_api_v1_fact_path(pointer.slug), headers: bearer(@admin), as: :json, params: { fact: { source_ref: "drive-2" } }
        assert_response :created, "a pointer is superseded by a pointer (control)"
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

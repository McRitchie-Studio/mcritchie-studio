require "test_helper"

module Api
  module V1
    # The desk-ledger endpoint — the write `bin/agent-worktree` makes BEFORE it destroys a
    # desk. It is on the destroy path, so the posture the CLI depends on is asserted here:
    # a refusal is a refusal (never an accepted-but-unrecorded 2xx), and a caller trying to
    # rewrite a resolved episode gets a distinguishable answer rather than a generic 422 it
    # would retry.
    class DeskRecordsControllerTest < ActionDispatch::IntegrationTest
      SHIP = "/Users/alex/projects/mcritchie-studio/.worktrees/_ship".freeze

      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}"
        }
      end

      def registry_desk(overrides = {})
        {
          "label" => "mcritchie-studio/_ship",
          "app" => "mcritchie-studio",
          "task" => "_ship",
          "task_record_slug" => "ship-it",
          "worktree" => SHIP,
          "branch" => "release",
          "head" => "be798149",
          "dirty" => false,
          "base_ref" => "origin/accepted",
          "merged_to_origin_main" => true,
          "health" => "down",
          "app_port" => 3024,
          "redis_db" => 24,
          "cleanup_candidate" => true,
          "cleanup_rationale" => "merged into origin/accepted, tree clean"
        }.merge(overrides)
      end

      # ---- [integration] auth ---------------------------------------------------

      test "[integration] requires a bearer token" do
        post api_v1_desk_records_url, params: { desk: { worktree_path: SHIP } }, as: :json

        assert_response :unauthorized
        assert_equal 0, DeskRecord.count
      end

      test "[integration] sync requires a bearer token" do
        post sync_api_v1_desk_records_url, params: { registry: { "worktrees" => [] } }, as: :json

        assert_response :unauthorized
      end

      # ---- [integration] filing one desk ----------------------------------------

      test "[integration] a teardown post files a dated, resolved episode" do
        post api_v1_desk_records_url,
             params: { desk: { registry: registry_desk, status: "removed", source: "remove",
                               safety: "merged", reason: "Hidden worktree; branch `release` is clean…",
                               safe_delete_condition: "Removed with `bin/agent-worktree remove …`." } },
             headers: @headers, as: :json

        assert_response :created
        record = DeskRecord.sole

        assert_equal SHIP, record.worktree_path
        assert_equal "removed", record.status
        assert_equal Date.current, record.resolved_on
        assert_equal "merged", record.safety
        assert_equal "remove", record.source
        # The CLI posts the registry record VERBATIM and the server owns the mapping, so a
        # column the poster never named is still filled.
        assert_equal "release", record.branch
        assert_equal 24, record.redis_db
        assert_equal registry_desk, record.payload
      end

      test "[integration] a nomination post files an open candidate" do
        post api_v1_desk_records_url,
             params: { desk: { registry: registry_desk, status: "candidate", source: "cleanup" } },
             headers: @headers, as: :json

        assert_response :created
        record = DeskRecord.sole

        assert_equal "candidate", record.status
        assert_nil record.resolved_on
        assert_equal record.id, DeskRecord.open_for(SHIP).id
      end

      test "[integration] worktree_path alone is enough when there is no registry record" do
        post api_v1_desk_records_url,
             params: { desk: { worktree_path: SHIP, status: "removed", source: "import",
                               reason: "recovered from a stranded stash" } },
             headers: @headers, as: :json

        assert_response :created
        assert_equal "recovered from a stranded stash", DeskRecord.sole.reason
      end

      test "[integration] a post with no desk path is refused, not stored" do
        post api_v1_desk_records_url, params: { desk: { status: "removed" } }, headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "MISSING_WORKTREE_PATH", response.parsed_body["error_code"]
        assert_equal 0, DeskRecord.count
      end

      test "[integration] an unknown status is refused by name" do
        post api_v1_desk_records_url,
             params: { desk: { worktree_path: SHIP, status: "torn-down" } },
             headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "INVALID_DESK_STATUS", response.parsed_body["error_code"]
        assert_equal 0, DeskRecord.count
      end

      # ---- [integration] a teardown's outcome -------------------------------------

      # bin/agent-worktree opens `removing` before it destroys anything and closes the same
      # episode with what it saw. A process it could not prove was the desk's survives, and
      # the close names it, so the Desks panel and any reader can tell it from a clean one.
      test "[integration] a teardown that spared a process closes its episode as leaked" do
        leak = [{ "pid" => 4242, "label" => "web", "via" => "pidfile", "port" => 3024, "cwd" => "/elsewhere" }]

        post api_v1_desk_records_url,
             params: { desk: { registry: registry_desk, status: "removing", source: "remove" } },
             headers: @headers, as: :json
        assert_response :created
        post api_v1_desk_records_url,
             params: { desk: { registry: registry_desk, status: "leaked", source: "remove", leaked_processes: leak } },
             headers: @headers, as: :json

        assert_response :created
        record = DeskRecord.sole
        assert_equal "leaked", record.status
        assert_equal Date.current, record.resolved_on
        assert_equal leak, record.leaked_processes
      end

      test "[integration] a leaked post that names no process is refused, not stored" do
        post api_v1_desk_records_url,
             params: { desk: { registry: registry_desk, status: "removing", source: "remove" } },
             headers: @headers, as: :json
        post api_v1_desk_records_url,
             params: { desk: { registry: registry_desk, status: "leaked", source: "remove" } },
             headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "INVALID_DESK_RECORD", response.parsed_body["error_code"]
        assert_equal "removing", DeskRecord.sole.status, "the open episode is left exactly as it was"
      end

      # ---- [integration] history is not rewritable over HTTP --------------------

      # A resolved episode is immutable in the model; this asserts the endpoint cannot talk
      # its way past that, and that the answer is DISTINGUISHABLE — a poster reading a 422
      # would retry, and retrying a write that must never succeed is how a caller ends up
      # spinning against a wall it cannot see.
      test "[integration] a second teardown of a recycled path opens a new episode" do
        2.times do
          post api_v1_desk_records_url,
               params: { desk: { registry: registry_desk, status: "removed", source: "remove" } },
               headers: @headers, as: :json
          assert_response :created
        end

        assert_equal 2, DeskRecord.where(worktree_path: SHIP).count
      end

      test "[integration] rewriting a resolved episode answers 409, not 422" do
        record = DeskRecord.file!(worktree_path: SHIP, status: "removed", resolved_on: Date.new(2026, 8, 18))
        # Force the endpoint at the resolved row by making the model hand it back as "open".
        DeskRecord.stub(:open_for, record) do
          post api_v1_desk_records_url,
               params: { desk: { registry: registry_desk, status: "removed", source: "remove" } },
               headers: @headers, as: :json
        end

        assert_response :conflict
        assert_equal "RESOLVED_RECORD_IMMUTABLE", response.parsed_body["error_code"]
        assert_equal Date.new(2026, 8, 18), record.reload.resolved_on
      end

      # ---- [integration] the bulk sync ------------------------------------------

      def registry_payload(desks: [], generated_at: "2026-08-31T21:39:33Z")
        {
          "generated_at" => generated_at,
          "projects_dir" => "/Users/alex/projects",
          "capacity" => { "current" => 55, "used" => 25, "free" => 30 },
          "summary" => { "worktrees" => desks.size, "dirty_worktrees" => 2, "withheld" => 57 },
          "worktrees" => desks
        }
      end

      test "[integration] a sync records the snapshot and every desk in it" do
        post sync_api_v1_desk_records_url,
             params: { registry: registry_payload(desks: [registry_desk, registry_desk("worktree" => "#{SHIP}-2", "label" => "b")]) },
             headers: @headers, as: :json

        assert_response :created
        body = response.parsed_body["data"]

        assert_equal 2, body["desks"]
        assert_equal 0, body["vanished"]
        assert_equal 2, DeskRecord.open_episodes.count
        assert_equal 30, DeskSnapshot.latest.free_slots
      end

      test "[integration] a sync reports desks that left without a teardown record" do
        post sync_api_v1_desk_records_url, params: { registry: registry_payload(desks: [registry_desk]) },
                                           headers: @headers, as: :json
        post sync_api_v1_desk_records_url,
             params: { registry: registry_payload(desks: [], generated_at: "2026-08-31T22:39:33Z") },
             headers: @headers, as: :json

        assert_response :created
        assert_equal 1, response.parsed_body["data"]["vanished"],
                     "an open record the newest snapshot did not see is the defect this table exists to catch"
      end

      # desk-ledger-stops-ghosting. The CLI's `managed` flag crosses the wire as a JSON
      # boolean; a reviewer's scratch worktree is counted but never opens an episode, so
      # when it is deleted with plain git nothing is left behind to read as vanished.
      test "[integration] a sync lists an unmanaged worktree without ledgering it" do
        scratch = "/private/tmp/claude-501/x/scratchpad/wt-carl-mutate"
        desks = [registry_desk("managed" => true),
                 registry_desk("worktree" => scratch, "label" => "wt", "managed" => false, "cleanup_candidate" => false)]
        payload = registry_payload(desks: desks)
        payload["summary"] = payload["summary"].merge("unmanaged" => 1)
        post sync_api_v1_desk_records_url, params: { registry: payload }, headers: @headers, as: :json

        assert_response :created
        assert_equal 2, response.parsed_body["data"]["desks"], "both desks are listed"
        assert_equal [SHIP], DeskRecord.open_episodes.pluck(:worktree_path), "only the managed desk is ledgered"
        assert_equal 1, DeskSnapshot.latest.unmanaged_desks

        post sync_api_v1_desk_records_url,
             params: { registry: registry_payload(desks: [], generated_at: "2026-08-31T22:39:33Z") },
             headers: @headers, as: :json

        assert_equal 1, response.parsed_body["data"]["vanished"],
                     "the managed desk that left is still reported; the scratch tree left no ghost"
      end

      test "[integration] a sync with no registry is refused" do
        post sync_api_v1_desk_records_url, params: { registry: {} }, headers: @headers, as: :json

        assert_response :unprocessable_entity
        assert_equal "MISSING_REGISTRY", response.parsed_body["error_code"]
      end

      # ---- [integration] reading back ------------------------------------------

      test "[integration] the index filters to open episodes and by app" do
        DeskRecord.file!(worktree_path: SHIP, status: "removed", app_slug: "mcritchie-studio")
        DeskRecord.file!(worktree_path: "#{SHIP}-2", status: "live", app_slug: "turf-monster")

        get api_v1_desk_records_url(open: 1), headers: @headers

        assert_response :success
        assert_equal ["#{SHIP}-2"], response.parsed_body["data"].map { |row| row["worktree_path"] }

        get api_v1_desk_records_url(app: "mcritchie-studio"), headers: @headers

        assert_equal [SHIP], response.parsed_body["data"].map { |row| row["worktree_path"] }
      end

      # ---- [integration] the retired import path ------------------------------------
      #
      # A stale copy of the harvest still names `import_key`. On the teardown path it would
      # answer 201 and file the row again, because `file!` resolves only OPEN episodes. It
      # gets a 410 by name and writes nothing, blank key or not.
      test "[integration] a post naming import_key is refused and writes nothing" do
        ["abc123", ""].each do |key|
          assert_no_difference -> { DeskRecord.count } do
            post "/api/v1/desk_records",
                 params: { desk: { import_key: key, worktree_path: SHIP, status: "removed", resolved_on: "2026-08-21" } },
                 headers: @headers, as: :json
          end
          assert_response :gone
          assert_equal "DESK_IMPORT_RETIRED", response.parsed_body["error_code"]
        end
      end

      # THE CONTROL: the same post without the field is an ordinary teardown write.
      test "[integration] the same post without import_key still files a record" do
        assert_difference -> { DeskRecord.count }, 1 do
          post "/api/v1/desk_records",
               params: { desk: { worktree_path: SHIP, status: "removed", resolved_on: "2026-08-21" } },
               headers: @headers, as: :json
        end
        assert_response :created
      end
    end
  end
end

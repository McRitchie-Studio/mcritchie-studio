require "test_helper"

# [integration] The provider side of the MS → turf-monster projection.
#
# The properties that matter are all about NOT LOSING ROWS: a consumer's
# replica going quietly short is the failure mode nobody notices, because
# nothing errors — a player is simply absent.
module Api
  module V1
    class AthletesControllerTest < ActionDispatch::IntegrationTest
      setup do
        Athlete.delete_all
        Person.where(last_name: "Sync").delete_all
      end

      def auth
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      def make(n, at: Time.current)
        person = Person.create!(first_name: "P#{n}", last_name: "Sync", athlete: true)
        a = Athlete.create!(person_slug: person.slug, sport: "football", gsis_id: "00-00#{format('%05d', n)}")
        a.update_column(:updated_at, at)
        a
      end

      def get_page(**params)
        get api_v1_athletes_path, params: params, headers: auth, as: :json
        JSON.parse(response.body)
      end

      test "rejects an unauthenticated caller" do
        get api_v1_athletes_path, as: :json
        assert_response :unauthorized
      end

      test "returns athletes with the league id the sync keys on" do
        make(1)
        body = get_page

        assert_response :success
        row = body["data"].first
        assert_equal "00-0000001", row["gsis_id"]
        assert row["person_slug"].present?
        assert row["updated_at"].present?
      end

      # A consumer with no watermark pages the world — there is no separate
      # "full rebuild" mode to get wrong.
      test "a nil watermark returns everything" do
        3.times { |i| make(i + 1) }

        assert_equal 3, get_page["data"].length
      end

      test "a watermark excludes rows older than it" do
        make(1, at: 3.days.ago)
        make(2, at: Time.current)

        body = get_page(updated_since: 1.day.ago.iso8601)
        assert_equal 1, body["data"].length
        assert_equal "00-0000002", body["data"].first["gsis_id"]
      end

      # THE ROW-DROPPING BUG THIS EXISTS TO PREVENT. A bulk import stamps
      # thousands of rows inside the same second; paging on updated_at alone
      # means a boundary landing mid-second skips every later row sharing that
      # timestamp, forever, with nothing reporting it.
      test "rows sharing one timestamp are not dropped across a page boundary" do
        same = Time.current.change(usec: 0)
        5.times { |i| make(i + 1, at: same) }

        seen = []
        cursor = { updated_since: 1.hour.ago.iso8601 }
        6.times do
          body = get_page(**cursor.merge(limit: 2))
          seen.concat(body["data"].map { |r| r["gsis_id"] })
          break unless body["meta"]["more"]

          cursor = { updated_since: body["meta"]["next_updated_since"],
                     after_id: body["meta"]["next_after_id"] }
        end

        assert_equal 5, seen.uniq.length,
                     "every row sharing the timestamp must be reachable by paging"
      end

      test "the cursor advances and terminates" do
        3.times { |i| make(i + 1) }

        first = get_page(limit: 2)
        assert_equal 2, first["data"].length
        assert first["meta"]["more"]

        second = get_page(updated_since: first["meta"]["next_updated_since"],
                          after_id: first["meta"]["next_after_id"], limit: 2)
        assert_equal 1, second["data"].length
        assert_not second["meta"]["more"]
      end

      test "page size is bounded so one caller cannot ask for everything" do
        body = get_page(limit: 99_999)
        assert_operator body["meta"]["count"], :<=, Api::V1::AthletesController::MAX_PAGE
      end

      test "an unparseable watermark is ignored rather than erroring" do
        make(1)
        body = get_page(updated_since: "not-a-time")

        assert_response :success
        assert_equal 1, body["data"].length
      end

      # So a consumer can tell "nothing changed" from "nothing was checked" —
      # a question no record's own updated_at can answer.
      test "the response reports when the source was last imported" do
        make(1)
        ImportRun.create!(source: "nflverse_players", started_at: 2.hours.ago,
                          finished_at: 1.hour.ago, status: "ok")

        assert get_page["meta"]["source_last_imported_at"].present?
      end

      test "results are ordered by the compound cursor" do
        t = Time.current
        make(2, at: t)
        make(1, at: t - 1.hour)

        ids = get_page["data"].map { |r| r["gsis_id"] }
        assert_equal ["00-0000001", "00-0000002"], ids
      end
    end
  end
end

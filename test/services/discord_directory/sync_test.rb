require "test_helper"
require_relative "../../support/report_destination_fixtures"

# [unit] DiscordDirectory::Sync — every channel and active thread of a guild is
# upserted with its kind, category, position and postable; a channel no longer
# seen is archived (never deleted) and comes back unarchived; a failed read
# leaves the guild as it was.
class DiscordDirectory::SyncTest < ActiveSupport::TestCase
  include ReportDestinationFixtures

  F = ReportDestinationFixtures

  def row(id) = DiscordChannel.find_by!(guild_external_id: GUILD, external_id: id)

  test "[unit] upserts every channel and active thread with kind, category, position and postable" do
    summary = sync_fake!(fake_discord)

    assert summary.ok?, summary.to_s
    assert_equal 9, summary.upserted
    assert_equal 9, DiscordChannel.in_guild(GUILD).count

    reports = row(F::REPORTS)
    assert_equal [ "text", "Ops", 0, F::CAT_OPS, true ], [ reports.kind, reports.category_name, reports.position, reports.parent_external_id, reports.postable ]
    assert_equal "announcement", row(F::NEWS).kind
    assert row(F::NEWS).postable
    assert_not row(F::LOCKED).postable, "the bot's role is denied SEND_MESSAGES there"
    assert_not row(F::HIDDEN).postable, "@everyone is denied VIEW_CHANNEL there"
    assert_equal "Secret", row(F::HIDDEN).category_name
    assert_equal [ "voice", false ], [ row(F::VOICE).kind, row(F::VOICE).postable ]
    assert_equal [ "forum", false ], [ row(F::FORUM).kind, row(F::FORUM).postable ], "a forum takes posts only as threads"
    assert_equal [ "category", nil ], [ row(F::CAT_OPS).kind, row(F::CAT_OPS).category_name ]

    thread = row(F::THREAD)
    assert_equal [ "thread", F::REPORTS, "Ops", true ], [ thread.kind, thread.parent_external_id, thread.category_name, thread.postable ]
    assert_equal [ F::REPORTS, F::NEWS, F::THREAD ].sort, DiscordChannel.selectable.pluck(:external_id).sort
  end

  test "[unit] a re-sync renames in place, archives what it no longer sees, and unarchives what returns" do
    fake = fake_discord
    sync_fake!(fake)
    first_id = row(F::REPORTS).id

    fake.channels = discord_channels_payload.reject { |c| c["id"] == F::NEWS }
                                            .map { |c| c["id"] == F::REPORTS ? c.merge("name" => "daily-reports") : c }
    fake.threads = discord_threads_payload(threads: [])
    summary = sync_fake!(fake)

    assert_equal 2, summary.archived
    assert_equal first_id, row(F::REPORTS).id, "an upsert keeps the row (and any destination on it)"
    assert_equal "daily-reports", row(F::REPORTS).name
    assert row(F::NEWS).archived?, "unseen is archived, not deleted"
    assert row(F::THREAD).archived?, "a thread no longer active is archived"
    assert_not DiscordChannel.selectable.exists?(external_id: F::NEWS)

    fake.channels = discord_channels_payload
    sync_fake!(fake)
    assert_not row(F::NEWS).archived?, "a channel that comes back is unarchived"
  end

  test "[unit] a failed channel read changes nothing; a failed thread read archives no thread" do
    fake = fake_discord
    sync_fake!(fake)

    fake.overrides = { "/channels" => [ 500, { "message" => "boom" } ] }
    summary = sync_fake!(fake)
    assert_not summary.ok?
    assert_match(/HTTP 500/, summary.errors.first)
    assert_equal 0, DiscordChannel.in_guild(GUILD).where.not(archived_at: nil).count

    fake.overrides = { "/threads/active" => [ 403, { "message" => "Missing Access" } ] }
    fake.channels = discord_channels_payload.reject { |c| c["id"] == F::NEWS }
    summary = sync_fake!(fake)
    assert_match(/threads/, summary.errors.first)
    assert row(F::NEWS).archived?
    assert_not row(F::THREAD).archived?, "an unread thread list is not an empty one"
  end

  test "[unit] unreadable roles fall back to postable for every message kind, and say so" do
    fake = fake_discord
    fake.overrides = { "/roles" => [ 403, { "message" => "Missing Access" } ] }
    summary = sync_fake!(fake)

    assert summary.ok?
    assert_match(/permissions unreadable/, summary.notes.join)
    assert row(F::LOCKED).postable
    assert_not row(F::VOICE).postable
  end

  test "[unit] the guilds are the ones config/agent_routes.yml lists" do
    assert_equal [ "1332466565203103744" ], DiscordDirectory::Sync.guild_ids
  end
end

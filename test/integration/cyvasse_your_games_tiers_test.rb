require "test_helper"
require "rake"

# [integration] The tiered "Your games" email end to end (task
# tiered-your-games-copy): Broadcast#stage! renders each reader through
# BroadcastMailer with the tier their games put them in, the subject and the
# body agree, Cyvasse Night is linked through the hub's click tracker in every
# tier, and broadcasts:restage refreshes held rows without sending.
class CyvasseYourGamesTiersTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  STATS = {
    "vet@example.com" => { "username" => "Vey", "games" => 27, "wins" => 20, "losses" => 7, "all_time_rank" => 12,
                           "joined_on" => "2014-03-02" },
    "reg@example.com" => { "username" => "Reg", "games" => 6, "wins" => 1, "joined_on" => "2019-05-01" },
    "zero@example.com" => { "username" => "Zed", "games" => 8, "wins" => 0 },
    "new@example.com" => { "username" => "Newt", "games" => 1 },
    "few@example.com" => { "username" => "Fey", "games" => 3, "wins" => 2 }
  }.freeze

  setup do
    @broadcast = Broadcast.create!(slug: "your-games-tiers", template_key: "cyvasse_your_games", target_list: "cyvasse-legacy",
                                   subject: "%{username}, your %{games} Cyvasse games are still here")
    @contacts = STATS.to_h do |email, stats|
      contact = Contact.create!(email: email, tags: [ "cyvasse-legacy" ], traits: { "cyvasse" => stats })
      contact.record_verification!(status: "valid")
      [ stats["username"], contact ]
    end
    @broadcast.stage!
  end

  def row(username) = @broadcast.staged_emails.find_by!(contact: @contacts.fetch(username))
  def text(html) = Nokogiri::HTML5(html).text.squish

  test "each tier's subject" do
    assert_equal "Vey, your 27 Cyvasse games are still here", row("Vey").rendered_subject
    assert_equal "Reg, your 6 games and 1 win are still here", row("Reg").rendered_subject
    assert_equal "Zed, your 8 Cyvasse games are still here", row("Zed").rendered_subject
    assert_equal "Newt, your Cyvasse account is still here", row("Newt").rendered_subject
    assert_equal "Fey, your Cyvasse account is still here", row("Fey").rendered_subject
  end

  test "veterans lead with their history: games, wins, rank and the year they joined" do
    vey = text(row("Vey").rendered_html)
    assert_includes vey, "You played 27 games of Cyvasse since joining in 2014, and every one of them is still there " \
                         "on the rebuilt game, along with your 20 wins. You still hold #12 on the all-time board."
    assert_includes vey, "Your games are still here"

    reg = text(row("Reg").rendered_html)
    assert_includes reg, "You played 6 games of Cyvasse since joining in 2019, and every one of them is still there " \
                         "on the rebuilt game, along with your 1 win."
    assert_not_includes reg, "all-time board", "no rank line without a rank"

    zed = text(row("Zed").rendered_html)
    assert_includes zed, "You played 8 games of Cyvasse, and every one of them is still there on the rebuilt game."
    assert_not_includes zed, "your 0 wins"
    assert_not_includes zed, "Your Cyvasse account and your history are waiting"
  end

  test "the 1-4 tier leads with the account waiting, pluralized, and no history block" do
    newt = Nokogiri::HTML5(row("Newt").rendered_html)
    assert_includes newt.text.squish, "Your Cyvasse account and your history are waiting for you on the rebuilt game, " \
                                      "including the 1 game you played. Come play whenever you like."
    assert_includes newt.text.squish, "Your account is still here"
    assert_empty newt.css('[data-tier="history"]')
    assert_not_includes newt.text, "1 games"

    fey = text(row("Fey").rendered_html)
    assert_includes fey, "including the 3 games you played"
    assert_not_includes fey, "You played"
    assert_not_includes fey, "Losses", "the stats table is the history tier's"
  end

  test "every tier invites to Cyvasse Night through a tracked link" do
    STATS.each_value do |stats|
      staged = row(stats["username"])
      html = Nokogiri::HTML5(staged.rendered_html)
      night = html.at_css('[data-block="night"]')
      assert night, "#{stats['username']} has no Cyvasse Night block"
      assert_includes night.text.squish, "Cyvasse Night on Tuesday, October 6, at 7 PM Mountain"
      href = night.at_css("a")["href"]
      assert_match %r{/e/c/#{staged.delivery_token}\?l=night\z}, href, "the night link goes through the tracker"
      assert_not_includes staged.rendered_html, "cyvasse.xyz/night", "no untracked night link in a sent email"
    end
    assert_equal "https://cyvasse.xyz/night", @broadcast.link_for("night"), "the tracker resolves the click here"
  end

  test "the queue preview points the night link at its destination, recording nothing" do
    assert_includes row("Newt").preview_html, 'href="https://cyvasse.xyz/night"'
  end

  test "the copy stays plain: no admin, no urgency" do
    STATS.each_value do |stats|
      body = text(row(stats["username"]).rendered_html).downcase
      %w[admin urgent hurry expire expires last\ chance].each { |word| assert_not_includes body, word }
    end
  end

  test "broadcasts:restage re-renders staged rows, prints counts, and sends nothing" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("broadcasts:restage")
    Rake::Task["broadcasts:restage"].reenable
    row("Vey").approve!
    StagedEmail.where(id: row("Newt").id).update_all(rendered_subject: "Newt, your 1 Cyvasse games are still here")
    vey_before = row("Vey").attributes

    out = nil
    assert_no_emails { assert_no_enqueued_jobs { out, = capture_io { Rake::Task["broadcasts:restage"].invoke(@broadcast.slug) } } }

    assert_match(/your-games-tiers: restaged 4, skipped 0, left 0/, out)
    assert_equal "Newt, your Cyvasse account is still here", row("Newt").rendered_subject
    assert_equal vey_before, row("Vey").attributes, "an approved row is never re-rendered"
  end
end

require "test_helper"

# [integration] The Cyvasse Night invite through the staged queue (task
# cyvasse-night-invite-email): Broadcast#stage! renders each reader through
# BroadcastMailer and stores the snapshot. A reader with stats and one without
# are both staged (no required fields), each with the subject their username
# picks, every link goes through the hub's click tracker, and the stored
# snapshot is what the staged mail sends.
class CyvasseNightStagedTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @broadcast = Broadcast.create!(slug: "cyvasse-night-staged", template_key: "cyvasse_night", target_list: "cyvasse-legacy",
                                   subject: "Cyvasse Night is Tuesday at 7 PM Mountain")
    @vet = contact("vet@example.com", "cyvasse" => { "username" => "Vey", "games" => 27, "wins" => 20 })
    @bare = contact("bare@example.com")
    assert_no_emails { assert_no_enqueued_jobs { @result = @broadcast.stage! } }
  end

  def contact(email, traits = {})
    Contact.create!(email: email, tags: [ "cyvasse-legacy" ], traits: traits).tap { |c| c.record_verification!(status: "valid") }
  end

  def row(contact) = @broadcast.staged_emails.find_by!(contact: contact)
  def text(html) = Nokogiri::HTML5(html).text.squish

  test "both readers are staged, none skipped, nothing sent" do
    assert_equal 2, @result.staged
    assert_equal 0, @result.skipped
    assert_equal %w[staged staged], [ row(@vet).status, row(@bare).status ]
  end

  test "each reader's subject and body follow their stats" do
    assert_equal "Vey, Cyvasse Night is Tuesday at 7 PM Mountain", row(@vet).rendered_subject
    assert_equal "Cyvasse Night is Tuesday at 7 PM Mountain", row(@bare).rendered_subject

    vey = text(row(@vet).rendered_html)
    assert_includes vey, "Hi Vey,"
    assert_includes vey, "Bring your 20 wins' worth of experience."

    bare = text(row(@bare).rendered_html)
    assert_includes bare, "Hi there,"
    assert_not_includes bare, "worth of experience"
    assert_not_includes bare, "{"
  end

  test "every stored link goes through the tracker with the row's token" do
    [ @vet, @bare ].each do |c|
      staged = row(c)
      assert_not_includes staged.rendered_html, "cyvasse.xyz", "no raw Cyvasse URL in a stored snapshot"
      hrefs = Nokogiri::HTML5(staged.rendered_html).css("a[href]").map { |a| a["href"] }
      %w[night play calendar build].each do |key|
        assert hrefs.any? { |h| h.match?(%r{/e/c/#{staged.delivery_token}\?l=#{key}\z}) }, "#{key} is tracked for #{c.email}"
      end
    end
  end

  test "the queue preview resolves the tracked links to their destinations" do
    preview = row(@bare).preview_html
    assert_includes preview, 'href="https://cyvasse.xyz/night"'
    assert_includes preview, 'href="https://cyvasse.xyz/night.ics"'
  end

  test "the staged mail sends the stored snapshot" do
    staged = row(@vet)
    staged.approve!
    mail = BroadcastMailer.staged(staged.reload).message
    assert_equal "Vey, Cyvasse Night is Tuesday at 7 PM Mountain", mail.subject
    html = mail.html_part ? mail.html_part.decoded : mail.decoded
    assert_equal staged.rendered_html, html
  end
end

require "test_helper"

# [unit] DeskCapture::Parser — the pure MIME extraction surface: sender,
# subject, body, attachments, and the entity hint (subject tag, then
# plus-address). Pure fixture-in structs-out; S3 and DB never appear.
class DeskCaptureParserTest < ActiveSupport::TestCase
  def raw_fixture
    File.read(Rails.root.join("test/fixtures/files/desk_sample.eml"))
  end

  test "parses sender, subject, body, and the attachment" do
    result = DeskCapture::Parser.parse(raw_fixture)

    assert_equal "amcritchie@gmail.com", result.from_addr
    assert_equal "[welding] Site visit transcript", result.subject
    assert_includes result.body_text, "press brake lease ends in November"
    assert_equal 1, result.attachments.size

    att = result.attachments.first
    assert_equal "Site Visit (Sep 2).txt", att.filename
    assert_includes att.body, "press brake lease ends in November"
  end

  test "subject tag maps to the canonical entity" do
    assert_equal "commercial-welding-llc", DeskCapture::Parser.parse(raw_fixture).entity_hint
  end

  test "plus-address routes when the subject carries no tag" do
    raw = raw_fixture.sub("Subject: [welding] Site visit transcript", "Subject: Site visit transcript")
                     .sub("Delivered-To: team@in.mcritchie.studio", "Delivered-To: team+industries@in.mcritchie.studio")
    assert_equal "mcritchie-industries", DeskCapture::Parser.parse(raw).entity_hint
  end

  test "no tag and no plus-address means no hint — the sweep decides" do
    raw = raw_fixture.sub("Subject: [welding] Site visit transcript", "Subject: Site visit transcript")
    assert_nil DeskCapture::Parser.parse(raw).entity_hint
  end

  test "sanitize_filename tames attachment names" do
    assert_equal "site-visit-sep-2.txt", DeskCapture::Parser.sanitize_filename("Site Visit (Sep 2).txt")
    assert_equal "attachment", DeskCapture::Parser.sanitize_filename("  ")
  end
end

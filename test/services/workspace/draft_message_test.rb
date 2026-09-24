require "test_helper"

# [unit] Workspace::DraftMessage — markdown in, the MIME a Gmail draft carries
# out. The motivating message is the operator's own: a sentence with a bold link.
class WorkspaceDraftMessageTest < ActiveSupport::TestCase
  BODY = "I'm running into some credit card declines when purchasing access to AI tools " \
         "like **[Claude](https://claude.ai)** and Higgsfield.\n\nThanks,\nAlex".freeze

  def draft(**overrides)
    Workspace::DraftMessage.new(from: "alex@mason.test", to: "billing@vendor.test",
                                subject: "Card declines", markdown: BODY, **overrides)
  end

  def parsed(**overrides) = Mail.new(draft(**overrides).to_mime)

  test "a bold link renders as a strong anchor in the HTML part" do
    html = parsed.html_part.decoded

    assert_includes html, '<strong><a href="https://claude.ai">Claude</a></strong>'
    assert_includes html, "<p>Thanks,<br>\nAlex</p>", "a single line break is a <br>, a blank line a paragraph"
  end

  test "the plain-text part keeps the link's URL and drops the markers" do
    text = parsed.text_part.decoded

    assert_includes text, "like Claude (https://claude.ai) and Higgsfield."
    refute_includes text, "**"
  end

  test "it is multipart/alternative with UTF-8 parts and the right headers" do
    mail = parsed(cc: "ops@mason.test, cfo@mason.test")

    assert mail.multipart?
    assert_equal "multipart/alternative", mail.mime_type
    assert_equal %w[billing@vendor.test], mail.to
    assert_equal %w[ops@mason.test cfo@mason.test], mail.cc
    assert_equal "Card declines", mail.subject
    assert_equal "UTF-8", mail.html_part.charset
  end

  test "raw HTML and javascript links in the source are never rendered" do
    html = parsed(markdown: "Hi <script>alert(1)</script> [x](javascript:alert(1)) <img src=https://t.test/p.gif>")
             .html_part.decoded

    refute_includes html, "<script>"
    refute_includes html, "<img"
    refute_includes html, 'href="javascript:'
    assert_includes html, "&lt;script&gt;"
  end

  test "no Message-ID leaks the composing machine's hostname" do
    mime = draft.to_mime

    refute_match(/^Message-ID:/i, mime.split("\r\n\r\n", 2).first)
  end

  test "reply headers ride along, and a signature is appended" do
    mail = parsed(in_reply_to: "<orig@vendor.test>", references: "<a@v.test> <orig@vendor.test>",
                  signature: "**Alex McRitchie**")

    assert_equal "orig@vendor.test", mail.in_reply_to
    assert_includes mail.header["References"].to_s, "<orig@vendor.test>"
    assert_includes mail.html_part.decoded, "<strong>Alex McRitchie</strong>"
  end

  test "a draft with no recipient or no body is refused" do
    assert_raises(ArgumentError) { draft(to: " , ") }
    assert_raises(ArgumentError) { draft(markdown: "  ") }
  end
end

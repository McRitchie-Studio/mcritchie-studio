require "test_helper"
require_relative "../../support/chat_attachment_samples"

# [unit] The files on a CTO web chat message (AgentMessages::Attachments and
# AgentMessages::WebIngest): the types the BYTES must be (PNG, JPEG, WebP, GIF,
# HEIC, PDF), the size caps (images 20 MB, a PDF 32 MB), at most 10 a message,
# the R2 key prefix that proves whose upload a blob is, the per-user upload
# limit, and a message that is files with no text.
class WebIngestAttachmentsTest < ActiveSupport::TestCase
  include ChatAttachmentSamples

  A = AgentMessages::Attachments

  setup do
    AgentPerson.seed_owner!
    @alex = users(:alex)
    @other = User.create!(email: "other@turf.example", name: "Other Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @other)
  end

  def ingest(text, tokens, user: @alex, app: "turf-monster", client_id: nil)
    AgentMessages::WebIngest.new(user: user, cto: AppOwnership.cto_for_app(app)).call(text, client_id: client_id,
                                                                                      attachments: tokens)
  end

  def refusal(&) = assert_raises(A::Refused, &)

  test "every allowed type is read from its bytes and stored under the app's chat prefix for its uploader" do
    expected = { "png" => "image/png", "jpg" => "image/jpeg", "webp" => "image/webp", "gif" => "image/gif",
                 "heic" => "image/heic", "pdf" => "application/pdf" }
    expected.each do |ext, type|
      blob = upload_sample(@alex, ext, name: "evil.exe")
      assert_equal type, blob.content_type, "#{ext}: the type is the bytes', never the name's"
      assert blob.key.start_with?("apps/turf-monster/chat/u#{@alex.id}-"), blob.key
    end
  end

  test "a disallowed type is refused at upload, whatever its name says" do
    error = refusal { upload_sample(@alex, "svg", name: "picture.png") }
    assert_equal "ATTACHMENT_TYPE", error.code
    assert_match(/not an image or a PDF/, error.message)
    error = refusal { A.upload!(io: StringIO.new("plain text, not a picture"), filename: "x.jpg", app_slug: "turf-monster", user: @alex) }
    assert_equal "ATTACHMENT_TYPE", error.code
    assert_equal 0, ActiveStorage::Blob.count, "a refused file is never stored"
  end

  test "the size caps: an image over 20 MB and a PDF over 32 MB are refused; at the cap is fine" do
    assert_equal "image", A.check!(content_type: "image/png", byte_size: 20.megabytes, filename: "a.png")
    assert_equal "pdf", A.check!(content_type: "application/pdf", byte_size: 32.megabytes, filename: "a.pdf")
    big_image = refusal { A.check!(content_type: "image/jpeg", byte_size: 20.megabytes + 1, filename: "a.jpg") }
    assert_equal [ "ATTACHMENT_TOO_BIG", "a.jpg is over 20 MB, the limit for an image." ], [ big_image.code, big_image.message ]
    big_pdf = refusal { A.check!(content_type: "application/pdf", byte_size: 32.megabytes + 1, filename: "a.pdf") }
    assert_match(/over 32 MB, the limit for a PDF/, big_pdf.message)
    assert_equal "ATTACHMENT_EMPTY", refusal { A.check!(content_type: "image/png", byte_size: 0, filename: "a.png") }.code
  end

  test "WebIngest re-checks each blob's size, so a blob that grew past its cap is refused at send" do
    blob = upload_sample(@alex, "png")
    blob.update_column(:byte_size, 20.megabytes + 1)

    error = refusal { ingest("look", [ A.token_for(blob) ]) }
    assert_equal "ATTACHMENT_TOO_BIG", error.code
    assert_equal 0, AgentMessage.count
  end

  test "a message carries at most 10 files" do
    tokens = Array.new(11) { sample_token(@alex, "png") }

    error = refusal { ingest("eleven", tokens) }
    assert_equal "ATTACHMENT_TOO_MANY", error.code
    assert_equal 0, AgentMessage.count

    message = ingest("ten", tokens.first(10))
    assert_equal 10, message.attachments.count
  end

  test "a message may be files with no text, and the files are attached before it can be claimed" do
    message = ingest("", [ sample_token(@alex, "png"), sample_token(@alex, "pdf") ])

    assert_equal [ "", "received" ], [ message.content, message.status ]
    assert_equal %w[image/png application/pdf], message.attachments.map { |a| a.blob.content_type }
    attached = message.events.find_by(kind: "attached")
    assert_equal({ "image" => 1, "pdf" => 1 }, attached.detail["kinds"])
    assert_equal 2, message.envelope["attachments"]
    assert_equal "EMPTY", refusal { ingest("  ", []) }.code, "no text and no files is still empty"
  end

  test "a token from another user, another app, or already sent is refused" do
    theirs = sample_token(@other, "png")
    assert_equal "ATTACHMENT_INVALID", refusal { ingest("mine?", [ theirs ]) }.code

    other_app = sample_token(@alex, "png", app: "mcritchie-studio")
    assert_equal "ATTACHMENT_INVALID", refusal { ingest("here?", [ other_app ]) }.code

    token = sample_token(@alex, "png")
    ingest("once", [ token ])
    assert_equal "ATTACHMENT_USED", refusal { ingest("twice", [ token ]) }.code
  end

  test "the token is not a blob id: Active Storage's public routes cannot open it, and it expires" do
    blob = upload_sample(@alex, "png")
    token = A.token_for(blob)

    assert_nil ActiveStorage::Blob.find_signed(token), "the default purpose (the public redirect route's) refuses it"
    travel A::TOKEN_TTL + 1.minute do
      assert_equal "ATTACHMENT_INVALID", refusal { ingest("late", [ token ]) }.code
    end
  end

  test "the per-user upload limit counts every app's chat uploads in the window" do
    A::UPLOAD_LIMIT.times { |i| ActiveStorage::Blob.create!(key: "apps/turf-monster/chat/u#{@alex.id}-x#{i}/a.png", filename: "a.png", byte_size: 1, checksum: "x", service_name: "test") }

    assert_equal "ATTACHMENT_RATE_LIMITED", refusal { upload_sample(@alex, "png") }.code
    assert upload_sample(@other, "png"), "another user's uploads do not count"
    travel A::UPLOAD_WINDOW + 1.minute do
      assert upload_sample(@alex, "png")
    end
  end

  test "a go that carries files is a message, not a confirm" do
    message = ingest("go", [ sample_token(@alex, "png") ])

    assert_equal "received", message.status
    assert_equal 1, message.attachments.count
  end

  test "the key keeps a safe filename and never the user's path" do
    blob = upload_sample(@alex, "png", name: "../../etc/My Screen shot (1).png")

    assert_match %r{\Aapps/turf-monster/chat/u#{@alex.id}-[a-z0-9]{24}/[A-Za-z0-9._-]+\z}, blob.key
    assert_not_includes blob.key, ".."
  end
end

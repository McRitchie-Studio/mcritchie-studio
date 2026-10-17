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

  teardown { A.enabled_override = nil }

  test "chat files live on the PRIVATE service, on the message and on the task it becomes" do
    assert_equal :chat_private, AgentMessage.reflect_on_attachment(:attachments).options[:service_name]
    assert_equal :chat_private, Task.reflect_on_attachment(:attachments).options[:service_name]
    assert_equal "chat_private", upload_sample(@alex, "png").service_name
    assert_not_equal ActiveStorage::Blob.service.name.to_s, "chat_private", "the hub's default (public-domain) bucket is another service"
  end

  test "OFF while the private bucket has no keys: uploads and files refused, text unchanged" do
    token = sample_token(@alex, "png")
    A.enabled_override = false

    assert_equal "ATTACHMENTS_OFF", refusal { upload_sample(@alex, "png") }.code
    error = refusal { ingest("look", [ token ]) }
    assert_equal [ "ATTACHMENTS_OFF", A::OFF_MESSAGE ], [ error.code, error.message ]
    assert_equal [], A.held([ token ], app_slug: "turf-monster", user: @alex)
    assert_equal "received", ingest("just text", []).status, "text chat is unchanged"
  end

  test "the switch reads the private service's keys: all three set is on, any missing is off, and off never boots a real bucket" do
    keys = { "CHAT_R2_ACCESS_KEY_ID" => "id", "CHAT_R2_SECRET_ACCESS_KEY" => "secret", "R2_ENDPOINT" => "https://acct.r2.cloudflarestorage.com" }
    assert StorageBackend.chat_private_configured?(keys)
    keys.each_key { |name| assert_not StorageBackend.chat_private_configured?(keys.merge(name => " ")), "#{name} blank" }

    on = StorageBackend.chat_private_service(keys, bucket: "mcritchie-studio-chat-dev")
    assert_equal %w[https://acct.r2.cloudflarestorage.com id secret mcritchie-studio-chat-dev], on.values_at("endpoint", "access_key_id", "secret_access_key", "bucket")
    off = StorageBackend.chat_private_service({ "R2_ENDPOINT" => "https://acct.r2.cloudflarestorage.com" }, bucket: "b")
    assert_equal "https://#{StorageBackend::UNCONFIGURED_HOST}", off["endpoint"], "off builds on the unreachable placeholder"
    assert_equal "mcritchie-studio-chat-production", StorageBackend.chat_private_bucket(qa: false, production: true)
    assert_equal "mcritchie-studio-chat-dev", StorageBackend.chat_private_bucket(qa: true, production: true)
    assert_equal "mcritchie-studio-chat-dev", StorageBackend.chat_private_bucket(qa: false, production: false)
  end

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

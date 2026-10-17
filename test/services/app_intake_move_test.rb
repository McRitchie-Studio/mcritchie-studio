require "test_helper"

# [unit] AppIntakeMove: a request's files under intake/<token>/ move to
# apps/<sub>/intake/ once its app exists: the object is copied, the blob's key
# repointed, the old object deleted, so nothing points at a missing object.
# Built against Active Storage blobs directly (the test service is Disk); the
# S3 path is the same three steps through the bucket's server-side copy.
class AppIntakeMoveTest < ActiveSupport::TestCase
  def queued_request(token: "tok_en-1")
    AppRequest.create!(prompt: "An app", token: token).tap do |r|
      r.update_columns(subdomain: "pawsome", status: "queued")
    end
  end

  def blob!(key, body = "bytes of #{key}")
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(body), filename: File.basename(key), key: key,
                                           content_type: "image/png")
  end

  test "each intake file is copied, repointed and its old object deleted; other files are untouched" do
    request = queued_request
    logo = blob!("intake/tok_en-1/logo.png", "logo")
    sketch = blob!("intake/tok_en-1/sketches/home.png", "sketch")
    other = blob!("intake/someone-else/logo.png")
    lookalike = blob!("intake/tok_en-12/logo.png", "a token that starts the same")
    service = ActiveStorage::Blob.service

    result = AppIntakeMove.new(request).call

    assert_equal 2, result.moved
    assert_equal "apps/pawsome/intake/logo.png", logo.reload.key
    assert_equal "apps/pawsome/intake/sketches/home.png", sketch.reload.key
    assert_equal "logo", logo.download, "the blob reads from its new key"
    assert_equal "sketch", sketch.download
    refute service.exist?("intake/tok_en-1/logo.png"), "the old object is deleted"
    refute service.exist?("intake/tok_en-1/sketches/home.png")
    assert_equal "intake/someone-else/logo.png", other.reload.key
    assert_equal "intake/tok_en-12/logo.png", lookalike.reload.key
  end

  test "a LIKE wildcard in the token matches only itself" do
    request = queued_request(token: "a_b")
    stranger = blob!("intake/axb/file.png")
    mine = blob!("intake/a_b/file.png")

    assert_equal 1, AppIntakeMove.new(request).call.moved
    assert_equal "apps/pawsome/intake/file.png", mine.reload.key
    assert_equal "intake/axb/file.png", stranger.reload.key
  end

  test "a re-run moves nothing more and loses nothing" do
    request = queued_request
    logo = blob!("intake/tok_en-1/logo.png", "logo")
    AppIntakeMove.new(request).call

    assert_equal 0, AppIntakeMove.new(request).call.moved
    assert_equal "logo", logo.reload.download
  end

  test "a repoint that fails leaves the blob on its old key, readable, and the next run finishes the move" do
    request = queued_request
    logo = blob!("intake/tok_en-1/logo.png", "logo")
    failing = ActiveStorage::Blob.find(logo.id)
    failing.define_singleton_method(:update_columns) { |*| raise ActiveRecord::StatementInvalid, "db down" }
    mover = AppIntakeMove.new(request)

    mover.stub(:blobs, [ failing ]) do
      assert_raises(ActiveRecord::StatementInvalid) { mover.call }
    end

    assert_equal "intake/tok_en-1/logo.png", logo.reload.key
    assert_equal "logo", logo.download, "the old object is kept until the key is repointed"
    AppIntakeMove.new(request).call
    assert_equal "apps/pawsome/intake/logo.png", logo.reload.key
    assert_equal "logo", logo.download
  end

  test "on the S3 service it copies server-side inside the bucket" do
    calls = []
    object = Struct.new(:key) do
      define_method(:copy_from) { |source| calls << [ :copy, source.key, key ] }
    end
    bucket = Object.new.tap { |b| b.define_singleton_method(:object) { |key| object.new(key) } }
    service = Object.new.tap do |s|
      s.define_singleton_method(:bucket) { bucket }
      s.define_singleton_method(:delete) { |key| calls << [ :delete, key ] }
    end
    request = queued_request
    blob = blob!("intake/tok_en-1/logo.png")

    blob.stub(:service, service) do
      AppIntakeMove.new(request).send(:move, blob)
    end

    assert_equal [ [ :copy, "intake/tok_en-1/logo.png", "apps/pawsome/intake/logo.png" ],
                   [ :delete, "intake/tok_en-1/logo.png" ] ], calls
    assert_equal "apps/pawsome/intake/logo.png", blob.reload.key
  end

  test "the job moves only a launched request's files" do
    draft = AppRequest.create!(prompt: "An app", token: "draft-tok")
    blob = blob!("intake/draft-tok/logo.png")
    AppIntakeMoveJob.perform_now(draft.id)
    assert_equal "intake/draft-tok/logo.png", blob.reload.key

    AppIntakeMoveJob.perform_now(queued_request.id)
    AppIntakeMoveJob.perform_now(0)
  end
end

require "test_helper"

# [unit] MINTING AND RECORDING A HIGGSFIELD CHARACTER IDENTITY.
#
# EVERY CALL TO THAT API COSTS REAL MONEY, so the client is injected here and
# never constructed: the fake below records what it was asked for and cannot
# reach a socket. A test that instantiated the real client would also fail on any
# machine without the production credential.
class Appearances::CreateCharacterReferenceTest < ActiveSupport::TestCase
  # Stands in for Higgsfield::Client. Deliberately NOT a Minitest mock: the
  # request shape is pinned by the client's own suite, and what matters here is
  # WHICH images this service gathered and WHETHER it called at all.
  class FakeClient
    attr_reader :creates, :reads

    def initialize(id: "1af15765-27b3-461a-8804-b2de098c72c3", status: "not_ready")
      @id = id
      @status = status
      @creates = []
      @reads = []
    end

    def create_custom_reference(name:, image_urls:)
      @creates << { name: name, image_urls: image_urls }
      @id
    end

    def custom_reference(id)
      @reads << id
      { "id" => id, "status" => @status, "fail_reason" => nil }
    end
  end

  setup do
    Appearance.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    @client = FakeClient.new
  end

  def service(references: ->(_look) { ["https://example.com/a.png"] }, client: @client)
    Appearances::CreateCharacterReference.new(@look, client: client, references: references)
  end

  test "the minted uuid is recorded against the look" do
    id = service.call

    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3", id
    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3", @look.reload.higgsfield_reference_id
  end

  # The create answers `not_ready`, so recording "ready" — or recording nothing —
  # would invite a generation pinned to an identity that is still training.
  test "the look records the not-ready state the create actually returns" do
    service.call

    assert_equal "not_ready", @look.reload.higgsfield_reference_status
    assert_not @look.higgsfield_reference_ready?, "an identity is never usable the moment it is made"
    assert @look.higgsfield_reference_pending?
    assert_not_nil @look.higgsfield_reference_synced_at
  end

  test "the reference list is whatever the injected collaborator returns" do
    service(references: ->(_look) { %w[https://e.com/1.png https://e.com/2.png https://e.com/3.png] }).call

    assert_equal %w[https://e.com/1.png https://e.com/2.png https://e.com/3.png],
                 @client.creates.first[:image_urls]
  end

  # THE SEAM THE IMAGE-SEARCH STEP PLUGS INTO. Nothing about this service knows
  # where a photograph came from, so a richer supplier is a constructor argument
  # rather than a rewrite.
  test "a richer supplier needs no change to this service" do
    search = ->(look) { ["https://cdn/#{look.person_slug}-front.png", "https://cdn/#{look.person_slug}-profile.png"] }

    service(references: search).call

    assert_equal ["https://cdn/josh-allen-front.png", "https://cdn/josh-allen-profile.png"],
                 @client.creates.first[:image_urls]
  end

  test "the default supplier is the cached-headshot floor" do
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "400",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/400.png", content_type: "image/png")

    Appearances::CreateCharacterReference.new(@look.reload, client: @client).call

    assert_equal 1, @client.creates.length
    assert_includes @client.creates.first[:image_urls].first, "/400.png"
  end

  # "We have no photographs" and "the vendor turned us down" have completely
  # different remedies, so they must not both be nil.
  test "no photographs raises rather than paying for an empty create" do
    assert_raises(Appearances::CreateCharacterReference::NoReferenceImages) do
      service(references: ->(_look) { [] }).call
    end

    assert_empty @client.creates
    assert_nil @look.reload.higgsfield_reference_id
  end

  # A second click must not buy a second identity — and because we store one id
  # per look and the vendor has no list endpoint, a re-create would strand the
  # first one where nothing could ever find it again.
  test "a look that already has an identity is not charged for another" do
    service.call
    assert_equal 1, @client.creates.length

    returned = service.call

    assert_equal 1, @client.creates.length, "the second call must not reach the vendor"
    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3", returned
  end

  test "a deliberate rebuild is still possible" do
    service.call
    other = FakeClient.new(id: "2bf15765-27b3-461a-8804-b2de098c72c3")

    service(client: other).call(force: true)

    assert_equal 1, other.creates.length
    assert_equal "2bf15765-27b3-461a-8804-b2de098c72c3", @look.reload.higgsfield_reference_id
  end

  # --- the status refresh -------------------------------------------------
  #
  # Without it the stored status is a permanent lie: the create stamps
  # `not_ready` and nothing else would ever move it, so the column that exists to
  # answer "may we pin a generation to this yet?" would always answer no.
  # Measured 2026-09-24 against a real reference: not_ready -> queued ->
  # in_progress -> completed.

  test "the refresh writes the vendor's current word and dates it" do
    service.call
    @look.update!(higgsfield_reference_synced_at: 2.days.ago)

    ready = FakeClient.new(status: "completed")
    status = Appearances::CreateCharacterReference.new(@look.reload, client: ready).refresh_status!

    assert_equal "completed", status
    assert_equal "completed", @look.reload.higgsfield_reference_status
    assert @look.higgsfield_reference_ready?
    assert_operator @look.higgsfield_reference_synced_at, :>, 1.hour.ago
    assert_equal ["1af15765-27b3-461a-8804-b2de098c72c3"], ready.reads
  end

  test "each state on the way to ready still reads as pending" do
    service.call

    %w[not_ready queued in_progress].each do |state|
      Appearances::CreateCharacterReference.new(@look.reload, client: FakeClient.new(status: state)).refresh_status!

      assert @look.reload.higgsfield_reference_pending?, "#{state} is on the way, not there"
      assert_not @look.higgsfield_reference_ready?, "#{state} must not unlock a paid generation"
    end
  end

  # A word we have never seen is more likely a failure than a success. Reading
  # readiness as "not one of the pending states" would call it ready.
  test "an unrecognised state is not read as ready" do
    service.call
    Appearances::CreateCharacterReference.new(@look.reload, client: FakeClient.new(status: "failed")).refresh_status!

    assert_not @look.reload.higgsfield_reference_ready?
    assert_not @look.higgsfield_reference_pending?, "a failure is not worth polling again"
  end

  test "a look with no identity has nothing to refresh and does not call out" do
    assert_nil Appearances::CreateCharacterReference.new(@look, client: @client).refresh_status!
    assert_empty @client.reads
  end

  # No list endpoint exists (GET on the collection answers 405), so the name is
  # the only thing a human can tell two identities apart by on the vendor's side.
  test "the vendor-side name carries the look it belongs to" do
    service.call

    name = @client.creates.first[:name]
    assert_includes name, "josh-allen"
    assert_includes name, "Bills home"
    assert_includes name, @look.slug
  end

  # A service that cannot be INSTANTIATED without a production key cannot be
  # tested on a laptop, and Higgsfield::Client raises when the credential is
  # absent.
  test "building the service does not construct a client" do
    ENV.stub(:[], nil) do
      assert_nothing_raised { Appearances::CreateCharacterReference.new(@look) }
    end
  end
end

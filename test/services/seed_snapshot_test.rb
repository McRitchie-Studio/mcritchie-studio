require "test_helper"
require "minitest/mock"

class SeedSnapshotTest < ActiveSupport::TestCase
  BODY = %({"name":"Beyoncé"}).b.freeze
  PIN = Digest::SHA256.hexdigest(BODY).freeze

  def with_store(configured: true, exists: true, body: BODY, &block)
    StorageBackend.stub(:configured?, configured) do
      Studio::S3.stub(:production_exists?, exists) do
        Studio::S3.stub(:production_download, ->(**) { body.dup }, &block)
      end
    end
  end

  test "reads the object as UTF-8 when it matches its pin" do
    with_store do
      body = SeedSnapshot.read("x.json", sha256: PIN)
      assert_equal Encoding::UTF_8, body.encoding
      assert_equal "Beyoncé", JSON.parse(body)["name"]
    end
  end

  test "answers nil when the object is absent" do
    with_store(exists: false) { assert_nil SeedSnapshot.read("x.json", sha256: PIN) }
  end

  test "answers nil without asking the store when there is no R2 connection" do
    StorageBackend.stub(:configured?, false) do
      Studio::S3.stub(:production_exists?, ->(**) { flunk "asked the store" }) do
        assert_nil SeedSnapshot.read("x.json", sha256: PIN)
      end
    end
  end

  test "raises on a changed object rather than seed from it" do
    with_store(body: "{}".b) do
      error = assert_raises(SeedSnapshot::ChecksumMismatch) { SeedSnapshot.read("x.json", sha256: PIN) }
      assert_includes error.message, "seed-data/x.json"
    end
  end

  test "a store failure reaches the caller instead of reading as absent" do
    boom = ->(**) { raise Studio::S3::Error, "403" }
    StorageBackend.stub(:configured?, true) do
      Studio::S3.stub(:production_exists?, boom) do
        assert_raises(Studio::S3::Error) { SeedSnapshot.read("x.json", sha256: PIN) }
      end
    end
  end

  test "every moved snapshot has a pin, read by default" do
    assert_equal %w[artists_wikidata.json spotrac_contracts_2025.json], SeedSnapshot::SHA256.keys.sort
    with_store(body: BODY) do
      assert_raises(SeedSnapshot::ChecksumMismatch) { SeedSnapshot.read("artists_wikidata.json") }
    end
  end

  test "publish refuses off production and uploads nothing" do
    Studio::S3.stub(:upload, ->(**) { flunk "uploaded" }) do
      assert_raises(SeedSnapshot::ProductionOnly) { SeedSnapshot.publish!(__FILE__, "x.json") }
    end
  end

  test "publish uploads under seed-data in production and answers the checksum" do
    Tempfile.create("snapshot", binmode: true) do |file|
      file.write(BODY)
      file.flush
      sent = nil
      Studio::S3.stub(:production_environment?, true) do
        Studio::S3.stub(:upload, ->(**args) { sent = args }) do
          assert_equal PIN, SeedSnapshot.publish!(file.path, "x.json")
        end
      end
      assert_equal "seed-data/x.json", sent[:key]
      assert_equal BODY, sent[:body]
    end
  end
end

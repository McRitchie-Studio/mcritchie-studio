# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../support/marketing_kit_fixtures"

# [integration] MarketingKit::Publisher across its Drive boundary, against an
# in-memory Drive that answers the same queries: a first publish builds the
# whole Layout, a second changes nothing, a changed upload is replaced in place,
# an existing Google file is kept unless named, a new Google file is a copy of
# its upload (the template gallery's rule), the root is shared per person and per
# domain once, and a dry run writes nothing.
class MarketingKitPublisherTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  # Holds files as a flat table and answers DriveClient's calls. Only the two
  # query shapes the publisher sends are understood; anything else fails loud.
  class FakeDrive
    Node = Struct.new(:id, :name, :mime_type, :parents, :body, :trashed, keyword_init: true) do
      def md5_checksum = mime_type.start_with?("application/vnd.google-apps") ? nil : Digest::MD5.hexdigest(body.to_s)
    end
    Perm = Struct.new(:type, :email_address, :domain, keyword_init: true)

    attr_reader :nodes, :writes, :perms

    def initialize
      @nodes = []
      @writes = []
      @perms = []
    end

    def paged(query:)
      if (m = query.match(/\A'(.+)' in parents and name = '(.+)' and trashed = false\z/))
        nodes.select { |n| !n.trashed && n.parents.include?(m[1]) && n.name == unq(m[2]) }
      elsif (m = query.match(/\Aname = '(.+)' and mimeType = '(.+)' and trashed = false\z/))
        nodes.select { |n| !n.trashed && n.name == unq(m[1]) && n.mime_type == m[2] }
      else
        raise "unexpected query #{query}"
      end
    end

    def files_create(name:, parents:, mime_type: nil, body: nil, content_type: nil)
      @writes << [:create, name]
      Node.new(id: "id#{nodes.size}", name: name, mime_type: mime_type || content_type, parents: parents, body: body).tap { |n| nodes << n }
    end

    def files_update(id, body: nil, content_type: nil)
      @writes << [:update, id]
      nodes.find { |n| n.id == id }.body = body
    end

    def files_copy(id, name:, parents:)
      @writes << [:copy, id]
      source = nodes.find { |n| n.id == id }
      Node.new(id: "id#{nodes.size}", name: name, mime_type: source.mime_type, parents: parents, body: source.body).tap { |n| nodes << n }
    end

    def files_trash(id)
      @writes << [:trash, id]
      nodes.find { |n| n.id == id }.trashed = true
    end

    def permissions_list(_id) = Struct.new(:permissions).new(@perms)

    def permissions_create(_id, email:)
      @writes << [:share, email]
      @perms << Perm.new(type: "user", email_address: email)
    end

    def permissions_create_domain(_id, domain:)
      @writes << [:share_domain, domain]
      @perms << Perm.new(type: "domain", domain: domain)
    end

    def find(name) = nodes.select { |n| n.name == name }

    private

    def unq(s) = s.gsub("\\'", "'").gsub("\\\\", "\\")
  end

  def publish(spec, out, drive, **opts)
    MarketingKit::Publisher.new(spec, manifest: File.join(out, "manifest.json"), drive: drive, **opts).run
  end

  def with_built_kit
    load_kit do |spec|
      Dir.mktmpdir do |out|
        MarketingKit::Build.new(spec, out: out, pdf: false, office: false).run
        yield spec, out
      end
    end
  end

  test "a first publish builds the layout and every file; a second changes nothing" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      first = publish(spec, out, drive)

      root = drive.find("Brand Kit: Ridgeline Fabrication").sole
      assert_equal root.id, first.root_id
      MarketingKit::Layout::FOLDERS.each do |path|
        assert drive.find(path.split("/").last).one? { |n| n.mime_type == MarketingKit::Publisher::FOLDER }, "folder #{path}"
      end
      start = drive.find("00 Start Here").sole
      assert_equal "application/vnd.google-apps.document", start.mime_type
      assert_equal [root.id], start.parents
      assert_equal 2, drive.find("RF_photo_shop-floor.jpg").size, "the master and its top-level copy"
      assert_equal [[:share, "owner@ridgeline.example"], [:share_domain, "ridgeline.example"], [:share_domain, "mcritchie.studio"]],
                   drive.writes.select { |w| w.first.start_with?("share") }

      drive.writes.clear
      second = publish(spec, out, drive)
      assert_empty drive.writes, "nothing written on a re-run"
      assert_equal %i[kept same shared], second.counts.keys.sort
    end
  end

  test "a new Google file is uploaded, copied to its real name, and the upload trashed" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      result = publish(spec, out, drive)

      upload = drive.find("#{MarketingKit::Publisher::UPLOAD_PREFIX}00 Start Here").sole
      start = drive.find("00 Start Here").sole
      assert upload.trashed, "the upload is trashed"
      refute start.trashed
      assert_equal [[:create, upload.name], [:copy, upload.id], [:trash, upload.id]],
                   drive.writes.select { |w| [upload.name, upload.id].include?(w.last) }, "upload, then copy, then trash"
      assert_equal [upload.parents, upload.mime_type, upload.body], [start.parents, start.mime_type, start.body]
      assert_equal start.id, result.results.find { |r| r.path == "00 Start Here" }.id, "the result names the copy"

      natives = drive.nodes.count { |n| n.mime_type.start_with?("application/vnd.google-apps.") && n.mime_type != MarketingKit::Publisher::FOLDER }
      assert_equal natives, 2 * drive.writes.count { |w| w.first == :copy }, "every Google file, and only those, is a copy of a trashed upload"
      assert_equal drive.writes.count { |w| w.first == :copy }, drive.writes.count { |w| w.first == :trash }
      photo = drive.find("RF_photo_shop-floor.jpg").first
      refute_includes drive.writes.map(&:last), photo.id, "an uploaded photo is never copied or trashed"
      assert_empty drive.find("#{MarketingKit::Publisher::UPLOAD_PREFIX}RF_photo_shop-floor.jpg")
    end
  end

  test "a replaced Google file is updated in place, never copied" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      publish(spec, out, drive)
      drive.writes.clear

      publish(spec, out, drive, replace: ["00 Start Here"])
      assert_equal [[:update, drive.find("00 Start Here").sole.id]], drive.writes
    end
  end

  test "a domain already shared is skipped; a missing one is added" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      drive.perms << FakeDrive::Perm.new(type: "domain", domain: "mcritchie.studio")
      result = publish(spec, out, drive)

      assert_equal [[:share_domain, "ridgeline.example"]], drive.writes.select { |w| w.first == :share_domain }
      assert_equal :shared, result.results.find { |r| r.path == "share mcritchie.studio" }.action
      assert_equal :share, result.results.find { |r| r.path == "share ridgeline.example" }.action
    end
  end

  test "a user permission does not count as the domain being shared" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      drive.perms << FakeDrive::Perm.new(type: "user", email_address: "someone@mcritchie.studio")
      publish(spec, out, drive)
      assert_includes drive.writes, [:share_domain, "mcritchie.studio"]
    end
  end

  test "a dry run against an existing kit reports a new domain share without writing it" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      publish(spec, out, drive)
      drive.perms.reject! { |p| p.domain == "ridgeline.example" }
      drive.writes.clear

      result = publish(spec, out, drive, dry_run: true)
      assert_empty drive.writes
      assert_equal :share, result.results.find { |r| r.path == "share ridgeline.example" }.action
      assert_equal :shared, result.results.find { |r| r.path == "share mcritchie.studio" }.action
    end
  end

  test "a changed upload is replaced in place, and a kept Google file only when named" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      publish(spec, out, drive)
      File.write(spec.photo_path("weld-closeup.jpg"), "a better photo")
      drive.writes.clear

      publish(spec, out, drive)
      photo = drive.find("RF_photo_weld-closeup.jpg").sole
      assert_equal [[:update, photo.id]], drive.writes
      assert_equal "a better photo", photo.body

      drive.writes.clear
      publish(spec, out, drive, replace: ["Brand Guide"])
      assert_equal [[:update, drive.find("Brand Guide").sole.id]], drive.writes

      drive.writes.clear
      result = publish(spec, out, drive, replace: :all)
      assert_equal result.results.count { |r| r.action == :update }, drive.writes.size
      assert_operator drive.writes.size, :>=, 5, "every Doc is overwritten"
    end
  end

  test "a dry run reports the whole kit and writes nothing" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      result = publish(spec, out, drive, dry_run: true)
      assert_empty drive.writes
      assert_empty drive.nodes
      assert_nil result.root_id
      manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
      assert_equal manifest.size + MarketingKit::Layout::FOLDERS.size + 1, result.counts[:create]
    end
  end

  test "two files of one name are reported, never guessed between" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      publish(spec, out, drive)
      start = drive.find("00 Start Here").sole
      drive.nodes << FakeDrive::Node.new(id: "dupe", name: "00 Start Here", mime_type: start.mime_type, parents: start.parents)
      drive.writes.clear

      result = publish(spec, out, drive, replace: :all)
      assert_equal :ambiguous, result.results.find { |r| r.path == "00 Start Here" }.action
      refute_includes drive.writes, [:update, start.id]
    end
  end

  test "two kit folders of the same name stop the publish" do
    with_built_kit do |spec, out|
      drive = FakeDrive.new
      2.times { drive.files_create(name: spec.root_name, parents: [], mime_type: MarketingKit::Publisher::FOLDER) }
      error = assert_raises(MarketingKit::Error) { publish(spec, out, drive) }
      assert_match(/set drive.root_id/, error.message)
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../support/marketing_kit_fixtures"

# [integration] MarketingKit::Publisher across its Drive boundary, against an
# in-memory Drive that answers the same queries: a first publish builds the
# whole Layout, a second changes nothing, a changed upload is replaced in place,
# an existing Google file is kept unless named, and a dry run writes nothing.
class MarketingKitPublisherTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  # Holds files as a flat table and answers DriveClient's calls. Only the two
  # query shapes the publisher sends are understood; anything else fails loud.
  class FakeDrive
    Node = Struct.new(:id, :name, :mime_type, :parents, :body, keyword_init: true) do
      def md5_checksum = mime_type.start_with?("application/vnd.google-apps") ? nil : Digest::MD5.hexdigest(body.to_s)
    end
    Perm = Struct.new(:email_address)

    attr_reader :nodes, :writes, :perms

    def initialize
      @nodes = []
      @writes = []
      @perms = []
    end

    def paged(query:)
      if (m = query.match(/\A'(.+)' in parents and name = '(.+)' and trashed = false\z/))
        nodes.select { |n| n.parents.include?(m[1]) && n.name == unq(m[2]) }
      elsif (m = query.match(/\Aname = '(.+)' and mimeType = '(.+)' and trashed = false\z/))
        nodes.select { |n| n.name == unq(m[1]) && n.mime_type == m[2] }
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

    def permissions_list(_id) = Struct.new(:permissions).new(@perms)

    def permissions_create(_id, email:)
      @writes << [:share, email]
      @perms << Perm.new(email)
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

      root = drive.find("Ridgeline Fabrication — Marketing Kit").sole
      assert_equal root.id, first.root_id
      MarketingKit::Layout::FOLDERS.each do |path|
        assert drive.find(path.split("/").last).one? { |n| n.mime_type == MarketingKit::Publisher::FOLDER }, "folder #{path}"
      end
      start = drive.find("00 Start Here").sole
      assert_equal "application/vnd.google-apps.document", start.mime_type
      assert_equal [root.id], start.parents
      assert_equal 2, drive.find("RF_photo_shop-floor.jpg").size, "the master and its top-level copy"
      assert_equal [[:share, "owner@ridgeline.example"]], drive.writes.select { |w| w.first == :share }

      drive.writes.clear
      second = publish(spec, out, drive)
      assert_empty drive.writes, "nothing written on a re-run"
      assert_equal %i[kept same shared], second.counts.keys.sort
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

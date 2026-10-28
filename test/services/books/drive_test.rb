# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"

# [unit] Books::Drive: each folder is found under its parent or created there,
# once per run; the Inbox query asks for PDFs in the Inbox only.
class BooksDriveTest < ActiveSupport::TestCase
  include BooksFixtures

  # A DriveClient stand-in holding a folder tree in memory.
  class ClientDouble
    attr_reader :queries, :created

    def initialize(existing = {})
      @existing = existing # { [parent, name] => id }
      @queries = []
      @created = []
    end

    def files_list(query:, limit: 100, **)
      @queries << query
      name = query[/name = '((?:[^'\\]|\\.)*)'/, 1]&.gsub("\\'", "'")
      parent = query[/'([^']+)' in parents/, 1]
      id = @existing[[ parent, name ]]
      Struct.new(:files).new(id ? [ Struct.new(:id).new(id) ] : [])
    end

    def files_create(name:, parents:, mime_type: nil, **)
      id = "made-#{name}"
      @created << [ parents.first, name, mime_type ]
      @existing[[ parents.first, name ]] = id
      Struct.new(:id).new(id)
    end

    def permissions_list(_id) = Struct.new(:permissions).new(@permissions ||= [])

    def permissions_create(id, email:, role:)
      (@shares ||= []) << [ id, email, role ]
      @permissions << Struct.new(:email_address).new(email)
    end

    def shares = @shares || []

    def paged(query:, **)
      @queries << query
      [ Struct.new(:id, :name, :modified_time).new("pdf-2", "b.pdf", "2026-10-02"), Struct.new(:id, :name, :modified_time).new("pdf-1", "a.pdf", "2026-10-01") ]
    end
  end

  test "ensure_tree finds what exists and creates only what is missing, under the right parent" do
    client = ClientDouble.new([ "root", "Example Books" ] => "books-root")
    tree = Books::Drive.new(books_entity, client: client).ensure_tree

    assert_equal "books-root", tree["root"]
    assert_equal [ [ "books-root", "Inbox", Books::Drive::FOLDER_MIME ], [ "books-root", "Statements", Books::Drive::FOLDER_MIME ],
                   [ "books-root", "Closes", Books::Drive::FOLDER_MIME ] ], client.created
  end

  test "setup shares the books root with share_with as a writer, once" do
    client = ClientDouble.new([ "root", "Example Books" ] => "books-root")
    entity = books_entity.dup.tap { |e| e.share_with = "Owner@Example.test" }
    drive = Books::Drive.new(entity, client: client)
    2.times { drive.ensure_tree }

    assert_equal [ [ "books-root", "owner@example.test", "writer" ] ], client.shares
  end

  test "a drive_subject that is not an ACTIVE workspace_account is refused by name, before any Google call" do
    error = assert_raises(Books::Drive::Error) { Books::Drive.new(books_entity).root }

    assert_match(/books@example.test is not an ACTIVE workspace_account/, error.message)
  end

  test "every configured entity keeps its books in its domain's team@ subject's Drive" do
    Books::Config.load.entities.each do |entity|
      domain = entity.drive_subject.split("@").last
      assert_equal WorkspaceAccount.default_subject_for(domain), entity.drive_subject,
                   "#{entity.key}: the hub may act in Drive only as the domain's workspace subject, never a mailbox"
    end
    studio = Books::Config.load.entity("studio")
    assert_equal [ "team@mcritchie.studio", "alex@mcritchie.studio" ], [ studio.drive_subject, studio.share_with ]
  end

  test "a folder is looked up once per run" do
    client = ClientDouble.new
    drive = Books::Drive.new(books_entity, client: client)
    2.times { drive.closes_folder("2026-09") }

    assert_equal 3, client.queries.size # root, Closes, 2026-09
  end

  test "the Inbox lists PDFs in the Inbox only, oldest first" do
    client = ClientDouble.new
    files = Books::Drive.new(books_entity, client: client).inbox_pdfs

    assert_equal %w[pdf-1 pdf-2], files.map { |f| f["id"] }
    assert_match(/'made-Inbox' in parents and mimeType = 'application\/pdf' and trashed = false/, client.queries.last)
  end

  test "a quote in a folder name is escaped in the query" do
    client = ClientDouble.new
    entity = books_entity.dup.tap { |e| e.drive_root = "Alex's Books" }
    Books::Drive.new(entity, client: client).root

    assert_includes client.queries.first, "name = 'Alex\\'s Books'"
    assert_equal [ [ "root", "Alex's Books", Books::Drive::FOLDER_MIME ] ], client.created
  end
end

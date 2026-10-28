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

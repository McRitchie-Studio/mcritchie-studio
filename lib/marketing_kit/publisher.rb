# frozen_string_literal: true

require "digest"
require "json"

module MarketingKit
  # Puts a built kit (Build's manifest.json) into Drive in the standard Layout.
  # Safe to run again: it finds folders and files by name and changes only what
  # it must.
  #
  #   - a missing folder or file is created;
  #   - an uploaded file (logo, photo, PDF) is replaced in place when its bytes
  #     differ, and left alone when they match;
  #   - a Google Doc, Sheet or Slides file that already exists is KEPT, because
  #     people edit them (the tracker's backlog, a template someone tidied).
  #     Name it in `replace:` (or pass replace: :all) to overwrite it in place;
  #   - two files of one name in one folder are never guessed between: the entry
  #     is reported and skipped;
  #   - a new Google file is a copy of its upload, so the template gallery
  #     takes it (see #upload);
  #   - the root is shared with drive.share_with (people) and
  #     drive.share_domains (whole Workspace domains), once each.
  #
  # dry_run: true reads Drive and reports, writing nothing.
  class Publisher
    FOLDER = "application/vnd.google-apps.folder"
    NATIVE = { "doc" => ["application/vnd.google-apps.document", "text/html"],
               "sheet" => ["application/vnd.google-apps.spreadsheet", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
               "slides" => ["application/vnd.google-apps.presentation", "application/vnd.openxmlformats-officedocument.presentationml.presentation"] }.freeze

    # The stand-in name a new Google file is uploaded under before its copy
    # takes the real name (see #upload).
    UPLOAD_PREFIX = "~upload "

    Result = Data.define(:action, :path, :id)

    attr_reader :results, :root_id

    def initialize(spec, manifest:, drive: Workspace::DriveClient.new(subject: spec.drive[:subject]), dry_run: false, replace: [])
      @spec = spec
      @entries = JSON.parse(File.read(manifest), symbolize_names: true)
      @drive = drive
      @dry_run = dry_run
      @replace = replace
      @folders = {}
      @results = []
    end

    def run
      @root_id = find_root
      @folders[Layout::ROOT] = @root_id
      Layout::FOLDERS.each { |path| folder(path) }
      @entries.each { |e| publish(e) }
      share
      self
    end

    def counts = results.group_by(&:action).transform_values(&:size)

    private

    def note(action, path, id = nil) = results << Result.new(action, path, id)

    def q(text) = text.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }

    def children(parent_id, name)
      return [] if parent_id.nil?

      @drive.paged(query: "'#{q(parent_id)}' in parents and name = '#{q(name)}' and trashed = false").to_a
    end

    def find_root
      return @spec.drive[:root_id] if @spec.drive[:root_id].present?

      hits = @drive.paged(query: "name = '#{q(@spec.root_name)}' and mimeType = '#{FOLDER}' and trashed = false").to_a
      raise Error, "#{hits.size} folders are named #{@spec.root_name.inspect}; set drive.root_id in the spec" if hits.size > 1
      return hits.first.id if hits.one?

      create(@spec.root_name, nil, FOLDER, @spec.root_name)
    end

    # Folder ids by layout path, made parent first. In a dry run a missing
    # folder's id is nil, so everything under it reads as "create".
    def folder(path)
      @folders.fetch(path) do
        parent_path = path.include?("/") ? path.rpartition("/").first : Layout::ROOT
        parent = folder(parent_path)
        name = path.split("/").last
        hits = children(parent, name).select { |f| f.mime_type == FOLDER }
        raise Error, "two folders named #{path.inspect}; merge them in Drive first" if hits.size > 1

        @folders[path] = hits.first&.id || create(name, parent, FOLDER, path)
      end
    end

    def publish(entry)
      parent = folder(entry[:folder])
      path = [entry[:folder].presence, entry[:name]].compact.join("/")
      hits = children(parent, entry[:name]).reject { |f| f.mime_type == FOLDER }
      return note(:ambiguous, path) if hits.size > 1
      return upload(entry, parent, path) if hits.empty?

      existing = hits.first
      if NATIVE.key?(entry[:kind])
        return note(:kept, path, existing.id) unless @replace == :all || Array(@replace).include?(entry[:name])
      elsif existing.md5_checksum == Digest::MD5.file(entry[:local]).hexdigest
        return note(:same, path, existing.id)
      end

      replace(entry, existing, path)
    end

    def upload(entry, parent, path)
      stored, sent = NATIVE.fetch(entry[:kind]) { [nil, Build.mime(entry[:local])] }
      return note(:create, path) if @dry_run

      body = File.binread(entry[:local])
      return note(:create, path, @drive.files_create(name: entry[:name], parents: [parent], body: body, content_type: sent).id) unless stored

      # A Google file made by upload and conversion is refused by the Docs and
      # Slides template gallery ("created from outside your organization"); an
      # API copy of it is accepted. So a new Google file is uploaded under a
      # stand-in name, copied to its real name beside it, and the upload trashed.
      draft = @drive.files_create(name: "#{UPLOAD_PREFIX}#{entry[:name]}", parents: [parent], mime_type: stored, body: body, content_type: sent)
      copy = @drive.files_copy(draft.id, name: entry[:name], parents: [parent])
      @drive.files_trash(draft.id)
      note(:create, path, copy.id)
    end

    def replace(entry, existing, path)
      return note(:update, path, existing.id) if @dry_run

      sent = NATIVE.fetch(entry[:kind]) { [nil, Build.mime(entry[:local])] }.last
      @drive.files_update(existing.id, body: File.binread(entry[:local]), content_type: sent)
      note(:update, path, existing.id)
    end

    def create(name, parent, mime, path)
      note(:create, "#{path}/")
      return nil if @dry_run

      @drive.files_create(name: name, parents: Array(parent), mime_type: mime).id
    end

    # Shares the root with each person in drive.share_with and each Workspace
    # domain in drive.share_domains, skipping any already shared.
    def share
      emails = Array(@spec.drive[:share_with])
      domains = @spec.share_domains
      return if (emails.empty? && domains.empty?) || @root_id.nil?

      perms = Array(@drive.permissions_list(@root_id).permissions)
      have = perms.filter_map { |p| p.email_address&.downcase }
      have_domains = perms.select { |p| p.type == "domain" }.filter_map { |p| p.domain&.downcase }
      emails.each do |email|
        next note(:shared, "share #{email}") if have.include?(email.downcase)
        next note(:share, "share #{email}") if @dry_run

        @drive.permissions_create(@root_id, email: email)
        note(:share, "share #{email}")
      end
      domains.each do |domain|
        next note(:shared, "share #{domain}") if have_domains.include?(domain)
        next note(:share, "share #{domain}") if @dry_run

        @drive.permissions_create_domain(@root_id, domain: domain)
        note(:share, "share #{domain}")
      end
    end
  end
end

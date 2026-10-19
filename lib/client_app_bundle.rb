# frozen_string_literal: true

require "digest"
require "find"
require "pathname"

# A client app's static bundle: the files one version of an app serves at
# <sub>.<preview domain> (docs/agents/system/client-app-host.md).
#
# PURE RUBY, on purpose: bin/client-bundle loads this file without Rails, so the
# CLI refuses a bad directory before it sends a byte, and the hub's publish
# (ClientApps::Publish) runs the SAME rules again on what arrived. The hub's
# check is the authoritative one; the CLI's is a courtesy.
#
#   bundle = ClientAppBundle.new({ "index.html" => "<!doctype html>…" })
#   bundle.errors     # => [] when it may be published
#   bundle.manifest   # => { "index.html" => { "size" =>, "sha256" =>, "content_type" => } }
#
#   ClientAppBundle.from_directory(dir)   # reads a directory, refusing symlinks
#
# What a bundle may hold (THE RULES):
#   - index.html at the root;
#   - at most MAX_FILES files and MAX_BYTES in all, MAX_FILE_BYTES per file;
#   - only the extensions in CONTENT_TYPES (no server code: no .rb, .php, .erb…);
#   - relative paths of plain segments ([A-Za-z0-9_-] and inner dots), no
#     dot-files, no "..", no absolute path, no backslash, at most MAX_DEPTH deep;
#   - when read from disk: regular files only, no symlinks (to a file or a dir).
class ClientAppBundle
  MAX_BYTES = 5 * 1024 * 1024
  MAX_FILE_BYTES = 3 * 1024 * 1024
  MAX_FILES = 200
  MAX_DEPTH = 6
  MAX_PATH = 200
  INDEX = "index.html"

  # The one extension list: what may be published, and the Content-Type the host
  # serves it with. Anything else is refused at publish, so the host never has
  # to guess a type.
  CONTENT_TYPES = {
    "html" => "text/html; charset=utf-8",
    "css" => "text/css; charset=utf-8",
    "js" => "text/javascript; charset=utf-8",
    "json" => "application/json; charset=utf-8",
    "svg" => "image/svg+xml",
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "webp" => "image/webp",
    "woff2" => "font/woff2",
    "ico" => "image/x-icon",
    "txt" => "text/plain; charset=utf-8"
  }.freeze

  SEGMENT = /\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/

  class Invalid < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super("bundle refused: #{@errors.join('; ')}")
    end
  end

  # The bundle in DIR: every regular file under it, keyed by its relative path.
  # Raises Invalid (naming each offender, never its content) for a symlink, a
  # special file, or a directory that does not exist. Stops reading once the
  # bundle is plainly too big, so a mistaken `/` is not slurped whole.
  def self.from_directory(dir)
    root = Pathname.new(dir.to_s).expand_path
    raise Invalid, "#{dir} is not a directory" unless root.directory? && !root.symlink?

    errors = []
    files = {}
    total = 0
    root.find do |path|
      next if path == root

      rel = path.relative_path_from(root).to_s
      if path.symlink?
        errors << "#{rel} is a symlink"
        Find.prune if path.directory?
      elsif path.directory?
        next
      elsif !path.file?
        errors << "#{rel} is not a regular file"
      else
        size = path.size
        total += size
        raise Invalid, errors + [ "the bundle passes #{MAX_BYTES} bytes" ] if total > MAX_BYTES
        raise Invalid, errors + [ "the bundle has more than #{MAX_FILES} files" ] if files.size >= MAX_FILES

        files[rel] = path.binread
      end
    end
    raise Invalid, errors if errors.any?

    new(files)
  end

  attr_reader :files

  # FILES: { relative path => bytes }.
  def initialize(files)
    @files = files.to_h { |path, bytes| [ path.to_s, bytes.to_s.b ] }
  end

  def self.content_type(path)
    CONTENT_TYPES[extension(path)]
  end

  def self.extension(path)
    name = path.to_s.split("/").last.to_s
    name.include?(".") ? name.split(".").last.downcase : ""
  end

  # Why this bundle cannot be published; empty when it can.
  def errors
    @errors ||= begin
      list = []
      list << "the bundle is empty" if files.empty?
      list << "the bundle has #{files.size} files, over #{MAX_FILES}" if files.size > MAX_FILES
      list << "the bundle is #{byte_size} bytes, over #{MAX_BYTES}" if byte_size > MAX_BYTES
      list << "#{INDEX} is required at the root" unless files.key?(INDEX)
      files.each { |path, bytes| list.concat(path_errors(path, bytes)) }
      list
    end
  end

  def valid? = errors.empty?

  def validate!
    raise Invalid, errors unless valid?

    self
  end

  def byte_size = files.values.sum(&:bytesize)

  # { path => { "size", "sha256", "content_type" } }, sorted by path: what the
  # host serves from (a path not in it is never fetched from storage).
  def manifest
    files.keys.sort.to_h do |path|
      bytes = files.fetch(path)
      [ path, { "size" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes),
                "content_type" => self.class.content_type(path) } ]
    end
  end

  private

  def path_errors(path, bytes)
    return [ "a path is blank" ] if path.empty?

    # A refused path is named only when it is printable and short, so a hostile
    # name cannot smuggle text into a log or the CLI's output.
    shown = path.length <= MAX_PATH && path.match?(/\A[[:print:]]+\z/) ? path : "a path"
    return [ "#{shown} is too long (over #{MAX_PATH} characters)" ] if path.length > MAX_PATH
    return [ "#{shown} is not a relative path" ] if path.start_with?("/") || path.include?("\\") || path.include?("\0")

    segments = path.split("/", -1)
    return [ "#{shown} is nested more than #{MAX_DEPTH} deep" ] if segments.size > MAX_DEPTH
    return [ "#{shown} has a dot-file or an empty, '.' or '..' segment" ] if segments.any? { |s| s.start_with?(".") || s.empty? }
    return [ "#{shown} has a character outside A-Z, a-z, 0-9, '.', '_' and '-'" ] unless segments.all? { |s| s.match?(SEGMENT) }
    return [ "#{shown} is not a static file type (allowed: #{CONTENT_TYPES.keys.join(', ')})" ] unless self.class.content_type(path)
    return [ "#{shown} is #{bytes.bytesize} bytes, over #{MAX_FILE_BYTES} for one file" ] if bytes.bytesize > MAX_FILE_BYTES

    []
  end
end

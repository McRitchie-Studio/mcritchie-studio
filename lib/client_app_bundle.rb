# frozen_string_literal: true

require "digest"
require "find"
require "pathname"
require_relative "client_app_markup"

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
#   - when read from disk: regular files only, no symlinks (to a file or a dir);
#   - THE STUDIO TEMPLATE (template_errors): every page puts its content in one
#     <main data-studio-content>, and nothing of the shell the host wraps it in
#     (the Studio navbar and footer, the kit under /_studio/) is the bundle's own.
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

  # The Studio template (docs/agents/system/client-app-host.md, "The Studio
  # template"). The host wraps every page in the Studio navbar and footer at
  # serve time, so a page carries only its content, in its content region.
  CONTENT_ATTRIBUTE = "data-studio-content"
  # The shell's own hooks: a page carrying one is shipping a copy of the shell.
  SHELL_HOOKS = %w[data-studio-navbar data-studio-footer data-studio-menu data-studio-kit data-studio-theme data-site-footer].freeze
  # What the host's kit owns: the bundle never names it, and never ships a
  # file under it.
  KIT_ROOT = "_studio"
  # Page chrome outside the content region would be a second navbar or footer.
  CHROME_TAGS = %w[header footer nav].freeze

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
      files.each { |path, bytes| list.concat(self.class.template_errors(path, bytes)) if self.class.extension(path) == "html" }
      list
    end
  end

  def valid? = errors.empty?

  def validate!
    raise Invalid, errors unless valid?

    self
  end

  def byte_size = files.values.sum(&:bytesize)

  # Why the page at PATH breaks the Studio template; empty when it keeps it.
  # Read through ClientAppMarkup, the SAME tag scanner the host's wrap uses (so
  # a page this accepts is a page the host places the shell in correctly), and
  # pure Ruby, so the CLI, the launcher and the hub all run it:
  #   - exactly one <main data-studio-content>, the region the content lives in;
  #   - no <header>, <footer> or <nav> before or after that region (the host
  #     puts the navbar and footer there; the app's own navigation goes inside);
  #   - none of the shell's own hooks (data-studio-navbar, data-site-footer, ...);
  #   - no reference to the kit's /_studio/ path.
  def self.template_errors(path, bytes)
    html = bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    tags = ClientAppMarkup.tags(html)
    starts = tags.select(&:start?)
    regions = starts.select { |tag| tag.name == "main" && tag.attributes.key?(CONTENT_ATTRIBUTE) }
    list = []
    if regions.size != 1
      list << "#{path} has #{regions.empty? ? 'no' : regions.size} content region#{'s' if regions.size > 1} " \
              "(one <main data-studio-content> holds the page; the host adds the Studio navbar and footer)"
    end
    if starts.any? { |tag| (tag.attributes.keys & SHELL_HOOKS).any? }
      list << "#{path} carries the Studio shell's own hooks (the host adds the navbar and footer; never ship a copy)"
    end
    list << "#{path} names /#{KIT_ROOT}/, the host's kit path" if html.gsub(/<!--.*?-->/m, "").include?("/#{KIT_ROOT}/")
    return list unless regions.size == 1

    region = regions.first
    finish = region_end(tags, region)
    outside = starts.select { |tag| tag.from < region.from || tag.from >= finish }
    outside.map(&:name).select { |name| CHROME_TAGS.include?(name) }.uniq.each do |name|
      list << "#{path} has a <#{name}> outside <main data-studio-content> (the host adds the Studio navbar and footer; " \
              "put the app's own navigation inside the content region)"
    end
    # The host puts the navbar right after the page's <body> tag (the same
    # scanner finds it), so that tag must open the page before its content.
    body = starts.find { |tag| tag.name == "body" }
    if body && body.from > region.from
      list << "#{path} opens <body> after its content region (the host would put the Studio navbar below the content)"
    end
    list
  end

  # Where the content region ends: its own </main>, counting nested <main>s.
  def self.region_end(tags, region)
    depth = 0
    tags.each do |tag|
      next if tag.from <= region.from || tag.name != "main"

      if tag.start? then depth += 1
      elsif depth.zero? then return tag.to
      else depth -= 1
      end
    end
    Float::INFINITY
  end

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
    return [ "#{shown} is under #{KIT_ROOT}/, which the host serves the Studio kit from" ] if segments.first == KIT_ROOT
    return [ "#{shown} is not a static file type (allowed: #{CONTENT_TYPES.keys.join(', ')})" ] unless self.class.content_type(path)
    return [ "#{shown} is #{bytes.bytesize} bytes, over #{MAX_FILE_BYTES} for one file" ] if bytes.bytesize > MAX_FILE_BYTES

    []
  end
end

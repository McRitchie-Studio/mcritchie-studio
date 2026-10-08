# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "time"
require "uri"
require_relative "desk_session"
require_relative "session_identity"

# bin/fact: read and write a subject's facts through the hub API
# (Api::V1::FactsController). The hub decides; this side asks and prints. It
# sends a key, a subject or a fact slug only when each is a name, so data typed
# into one never leaves the shell, and it repeats none of them in a refusal.
#
# The bearer is an agent session's token: AGENT_ADMIN_SESSION_TOKEN when the
# shell holds one, else the studio session of the desk this runs in. The shared
# token is never sent; the hub refuses it.
module FactCli
  class Failure < StandardError; end

  DEFAULT_API = "https://mcritchie.studio"
  ADMIN_TOKEN_ENV = "AGENT_ADMIN_SESSION_TOKEN"
  SUBJECT_TYPES = %w[person company app].freeze
  SOURCE_KINDS = { "knowledge" => "knowledge_doc", "drive" => "drive_file" }.freeze
  # Fact's own key grammar (Fact::KEY_FORMAT, KEY_MAX, LONG_NUMBER); fact_test.rb pins the three.
  KEY_FORMAT = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/
  KEY_MAX = 64
  LONG_NUMBER = 8
  SUBJECT_SLUG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  FACT_SLUG = /\Afact-[0-9a-f]+\z/
  KEY_REFUSAL = "--add takes key=value, or a bare key for a pointer. The key is lowercase words and digits joined " \
                "by a hyphen or an underscore (year-founded), #{KEY_MAX} characters at most, and carries no long " \
                "number: a colon or a space is not the equals sign. Nothing was sent."
  USAGE = <<~TEXT
    Usage: bin/fact <subject> [--history] [--reveal]
           bin/fact <subject> --add key=value --source <doc> [--note TEXT] [--sensitive]
           bin/fact <subject> --add key --source <doc>            a pointer: no value, only the source
           bin/fact --supersede <fact-slug> --value VALUE --source <doc> [--note TEXT]
           bin/fact --retire <fact-slug>

    <subject>  person/<slug>, company/<slug> or app/<slug>; a bare slug is a person
    <doc>      a knowledge doc id, or drive:<file id> for a Google Drive file
    key        a name: lowercase words and digits joined by a hyphen or an underscore (year-founded).
               A key that names identity data (ssn, bank-account, card, password) takes no value.
  TEXT
  NO_SESSION = "bin/fact needs an agent session, and the hub refuses the shared token. Run it from the desk of " \
               "a task you hold (bin/task begin logs the desk in), or hold an admin session's token in " \
               "#{ADMIN_TOKEN_ENV}."

  module_function

  # The run `argv` asks for. An unknown flag raises OptionParser::InvalidOption.
  def parse(argv)
    options = { history: false, reveal: false, sensitive: false }
    parser = OptionParser.new do |opts|
      opts.banner = USAGE
      opts.on("--add PAIR", "key=value to record, or a bare key for a pointer") { |v| options[:add] = v }
      opts.on("--source DOC", "where it came from: a knowledge doc id, or drive:<file id>") { |v| options[:source] = v }
      opts.on("--note TEXT", "a free note on the source (a page, a date)") { |v| options[:note] = v }
      opts.on("--sensitive", "record it as sensitive (admin session only)") { options[:sensitive] = true }
      opts.on("--supersede SLUG", "replace this fact with --value and --source") { |v| options[:supersede] = v }
      opts.on("--value VALUE", "the new value for --supersede") { |v| options[:value] = v }
      opts.on("--retire SLUG", "end this fact") { |v| options[:retire] = v }
      opts.on("--history", "list superseded and retired facts too") { options[:history] = true }
      opts.on("--reveal", "print sensitive values (masked by default)") { options[:reveal] = true }
      opts.on("--api URL", "another hub, e.g. a desk server (default #{DEFAULT_API})") { |v| options[:api] = v }
      opts.on("-h", "--help") { options[:help] = true }
    end
    rest = parser.parse(argv)
    return options if options[:help]

    by_slug = options[:supersede] || options[:retire]
    raise Failure, "--supersede and --retire are separate runs" if options[:supersede] && options[:retire]
    raise Failure, "exactly one subject, got #{rest.size}\n#{USAGE}" if !by_slug && rest.size != 1
    raise Failure, "--supersede and --retire take a fact slug, not a subject" if by_slug && rest.any?
    raise Failure, "--add needs --source: every fact names where it came from" if options[:add] && options[:source].to_s.empty?
    raise Failure, "--supersede needs --value and --source" if options[:supersede] && (options[:value].to_s.empty? || options[:source].to_s.empty?)

    raise Failure, "--supersede and --retire take a fact slug (fact-<hex>). Nothing was sent." if by_slug && !FACT_SLUG.match?(by_slug)

    options[:subject] = subject(rest.first) unless by_slug
    options[:pair] = pair(options[:add]) if options[:add]
    options
  end

  # [key, value] from "key=value", split at the first equals sign; a bare key
  # has no value. A key that is not a name raises without being repeated.
  def pair(raw)
    key, value = raw.to_s.split("=", 2)
    key = key.to_s.strip
    raise Failure, KEY_REFUSAL unless key.length <= KEY_MAX && KEY_FORMAT.match?(key) && key.count("0-9") < LONG_NUMBER

    [key, value]
  end

  # [type, slug] from "person/josh-allen"; a bare slug is a person.
  def subject(raw)
    type, slug = raw.to_s.include?("/") ? raw.to_s.split("/", 2) : ["person", raw.to_s]
    raise Failure, "unknown subject type; one of #{SUBJECT_TYPES.join(", ")}" unless SUBJECT_TYPES.include?(type)
    raise Failure, "the subject needs a slug" if slug.to_s.empty?
    unless SUBJECT_SLUG.match?(slug) && slug.count("0-9") < LONG_NUMBER
      raise Failure, "the subject slug is lowercase words and digits joined by hyphens, with no long number. Nothing was sent."
    end

    [type, slug]
  end

  # { source_kind:, source_ref: } from "doc-id", "knowledge:doc-id" or "drive:file-id".
  def source(raw)
    prefix, ref = raw.to_s.split(":", 2)
    return { source_kind: SOURCE_KINDS.fetch(prefix), source_ref: ref } if ref && SOURCE_KINDS.key?(prefix)

    { source_kind: "knowledge_doc", source_ref: raw.to_s }
  end

  # The session token to present, or nil: the admin token the shell holds, else
  # the live studio session of the desk at `root` when this harness opened it.
  def session_token(env: ENV, root: DeskSession.root_for(Dir.pwd), now: Time.now)
    admin = env[ADMIN_TOKEN_ENV].to_s.strip
    return admin unless admin.empty?

    data = DeskSession.read(root)
    return nil unless data && !data["token"].to_s.empty? && DeskSession.live?(data, now)
    return nil unless data["harness_session_id"].to_s == SessionIdentity.id(env) && !SessionIdentity.id(env).empty?

    data["token"]
  end

  # Net::HTTP against one hub with one bearer; a refusal raises with the hub's reason.
  class Api
    def initialize(base_url:, token:)
      @base = base_url.to_s.chomp("/")
      @token = token
    end

    def get(path) = data(request(Net::HTTP::Get, path, nil))
    def post(path, payload = nil) = data(request(Net::HTTP::Post, path, payload))

    private

    def data(res)
      body = JSON.parse(res.body.to_s) rescue {}
      return body["data"] if res.is_a?(Net::HTTPSuccess)

      raise Failure, "hub answered #{res.code}: #{[body["error_code"], body["error"] || "no reason given"].compact.join(" ")}"
    end

    def request(klass, path, payload)
      uri = URI.join("#{@base}/", path.delete_prefix("/"))
      req = klass.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{@token}")
      req.body = JSON.generate(payload) if payload
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) { |http| http.request(req) }
    rescue SystemCallError, SocketError, Timeout::Error => e
      raise Failure, "could not reach #{@base}: #{e.class}"
    end
  end

  class Runner
    def initialize(api:, out: $stdout)
      @api = api
      @out = out
    end

    def run(options)
      if options[:supersede] then supersede(options)
      elsif options[:retire] then retire(options[:retire])
      elsif options[:add] then add(options)
      else list(options)
      end
    end

    def list(options)
      type, slug = options.fetch(:subject)
      query = URI.encode_www_form({ subject_type: type, subject_slug: slug, history: (1 if options[:history]) }.compact)
      facts = @api.get("/api/v1/facts?#{query}")
      return @out.puts("#{type}/#{slug}: no facts on file") if facts.empty?

      facts.each { |fact| @out.puts(line(fact, reveal: options[:reveal])) }
    end

    def add(options)
      type, slug = options.fetch(:subject)
      key, value = options.fetch(:pair)
      fact = { subject_type: type, subject_slug: slug, key: key, value: value, source_note: options[:note],
               sensitivity: ("sensitive" if options[:sensitive]) }.merge(FactCli.source(options[:source])).compact
      recorded("recorded", @api.post("/api/v1/facts", { fact: fact }))
    end

    def supersede(options)
      fact = { value: options[:value], source_note: options[:note] }.merge(FactCli.source(options[:source])).compact
      recorded("superseded #{options[:supersede]} with", @api.post("/api/v1/facts/#{options[:supersede]}/supersede", { fact: fact }))
    end

    def retire(slug)
      fact = @api.post("/api/v1/facts/#{slug}/retire")
      @out.puts "retired #{fact["slug"]} (#{fact["subject_type"]}/#{fact["subject_slug"]} #{fact["key"]})"
    end

    private

    # A write's confirmation names the fact, never its value.
    def recorded(verb, fact)
      kind = fact["pointer"] ? "pointer" : fact["sensitivity"]
      @out.puts "#{verb} #{fact["slug"]} (#{fact["subject_type"]}/#{fact["subject_slug"]} #{fact["key"]}, #{kind}, " \
                "source #{source_label(fact)})"
    end

    def line(fact, reveal:)
      state = if fact["retired_at"] then " [retired]"
              elsif fact["superseded_by_slug"] then " [superseded by #{fact["superseded_by_slug"]}]"
              else ""
              end
      "#{fact["key"]}: #{shown(fact, reveal)}#{state}\n  #{fact["slug"]} · source #{source_label(fact)} · " \
        "recorded by #{fact["recorded_by"] || "an ended session"} #{fact["recorded_at"].to_s[0, 10]}"
    end

    def shown(fact, reveal)
      return "(pointer: the original is at the source)" if fact["pointer"]
      return "(sensitive; --reveal prints it)" if fact["sensitivity"] == "sensitive" && !reveal

      fact["value"]
    end

    def source_label(fact)
      source = fact["source"] || {}
      label = source["kind"] == "drive_file" ? "drive:#{source["ref"]}" : source["ref"].to_s
      source["note"].to_s.empty? ? label : "#{label} (#{source["note"]})"
    end
  end
end

# frozen_string_literal: true

# bin/lib/dev_google_client.rb: point every local env file at the dev-only Google
# OAuth client. The client lives in the agent vault as ITEM (fields `client-id`
# and `client-secret`); the deployed apps' clients are the ones in
# config/google_oauth_clients.yml, which a local boot refuses
# (Devops::GoogleOAuthClients). Rails-free; bin/dev-google-client is the CLI.
#
# What it never does: print a value. Every report is a path, a key and a verb.
require_relative "dev_secret_key"
require_relative "../../app/models/devops/google_oauth_clients"

module DevGoogleClient
  class Error < StandardError; end

  VAULT = "studio-agents"
  ITEM = "google.studio.local"
  FIELDS = { "GOOGLE_CLIENT_ID" => "client-id", "GOOGLE_CLIENT_SECRET" => "client-secret" }.freeze
  KEYS = FIELDS.keys.freeze

  module_function

  # `KEY=value`, `export KEY=value`, leading space allowed; captures the lead, the
  # value and the line ending so a rewrite keeps everything but the value.
  def line_pattern(key)
    /\A(\s*(?:export\s+)?#{Regexp.escape(key)}\s*=)(.*?)(\r?\n)?\z/m
  end

  # The client from the vault: {id:, secret:}. Both fields must be filled; an
  # empty item is the state before Alex pastes the client from the Cloud console,
  # and it refuses by name so the next step is plain.
  def read_from_vault(item: ITEM, vault: VAULT, reader: method(:op_read))
    values = FIELDS.to_h { |key, field| [key, reader.call("op://#{vault}/#{item}/#{field}").to_s.strip] }
    empty = values.select { |_, v| v.empty? }.keys
    unless empty.empty?
      raise Error, "#{vault}/#{item} has no #{empty.map { |k| FIELDS[k] }.join(' or ')} yet: create the dev OAuth " \
                   "client in the Cloud console and paste both fields into the item, then run again"
    end
    if Devops::GoogleOAuthClients.production?(values["GOOGLE_CLIENT_ID"])
      raise Error, "#{vault}/#{item} holds a PRODUCTION client id (#{Devops::GoogleOAuthClients.apps_for(values['GOOGLE_CLIENT_ID']).join(', ')}); " \
                   "the dev item must hold the dev-only client"
    end
    { id: values["GOOGLE_CLIENT_ID"], secret: values["GOOGLE_CLIENT_SECRET"] }
  end

  def op_read(ref)
    out = IO.popen(["op", "read", ref], err: File::NULL, &:read)
    $?.success? ? out : "" # rubocop:disable Style/SpecialGlobalVars
  end

  # Set `key` to `value` in `path`: every line that sets the key is rewritten,
  # every other line is kept byte for byte, and the file mode survives. A file
  # with no such line gets one appended. Returns :rewritten, :appended or
  # :skipped (the file does not exist; env files are never created here).
  def rewrite_key(path, key, value)
    return :skipped unless File.file?(path)

    pattern = line_pattern(key)
    replaced = false
    lines = File.readlines(path).map do |line|
      m = pattern.match(line) or next line
      replaced = true
      "#{m[1]}#{value}#{m[3] || "\n"}"
    end
    verb = :rewritten
    unless replaced
      lines[-1] = "#{lines[-1]}\n" if lines.any? && !lines[-1].end_with?("\n")
      lines << "#{key}=#{value}\n"
      verb = :appended
    end
    DevSecretKey.atomic_write(path, lines.join)
    verb
  end

  # Which files to touch: every local env file that sets GOOGLE_CLIENT_ID to
  # anything (a template with an empty value or a comment is left alone, as is a
  # file with no Google line at all). {path => current id} for the plan.
  def candidates(files)
    files.filter_map do |path|
      id = DevSecretKey.read_value(path, "GOOGLE_CLIENT_ID").to_s.strip
      [path, id] unless id.empty?
    end.to_h
  end

  # The plan for `files`, as counts and paths, never values. `write: true` applies
  # it. Returns {files: [...], counts: {key => {verb => n}}, production: n} where
  # `production` counts files still pointing at a deployed app's client before
  # the rewrite.
  def apply(files, id:, secret:, write: false)
    targets = candidates(files)
    production = targets.count { |_, current| Devops::GoogleOAuthClients.production?(current) }
    counts = KEYS.to_h { |key| [key, Hash.new(0)] }
    if write
      targets.each_key do |path|
        counts["GOOGLE_CLIENT_ID"][rewrite_key(path, "GOOGLE_CLIENT_ID", id)] += 1
        counts["GOOGLE_CLIENT_SECRET"][rewrite_key(path, "GOOGLE_CLIENT_SECRET", secret)] += 1
      end
    end
    { files: targets.keys, counts: counts, production: production }
  end

  # The lines a run prints: paths and counts only.
  def report_lines(result, write:)
    lines = result[:files].map { |path| "#{path}  #{write ? 'rewritten' : 'would rewrite'}" }
    lines << "#{result[:files].size} file(s) set GOOGLE_CLIENT_ID; #{result[:production]} of them on a production client"
    if write
      KEYS.each do |key|
        c = result[:counts][key]
        lines << "#{key}: #{c[:rewritten]} rewritten, #{c[:appended]} appended, #{c[:skipped]} skipped"
      end
    else
      lines << "dry run: nothing written; pass --write to point them at the dev client"
    end
    lines
  end
end

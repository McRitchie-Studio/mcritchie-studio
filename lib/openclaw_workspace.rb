# frozen_string_literal: true

require "yaml"
require "fileutils"

# Builds an OpenClaw agent workspace from a soul's docs (task
# tyrion-fleet-onboarding), so a fleet soul can run on an OpenClaw box with the
# same character the repo gives it. bin/openclaw-workspace is the command.
#
# OpenClaw injects SOUL.md, AGENTS.md and IDENTITY.md into every session
# (docs.openclaw.ai/concepts/agent-workspace), each capped at 20,000
# characters and 60,000 together. A soul may say which of its docs make up
# each file in docs/agents/agents/<soul>/openclaw.yml; without one, SOUL.md is
# soul.md and AGENTS.md is role.md.
#
# Only those three files are written. Anything else in the workspace (the
# agent's own MEMORY.md, memory/, skills/) is left alone, so re-running after a
# docs change refreshes the character without wiping what the agent learned.
# Links between repo docs mean nothing inside a workspace, so they are
# flattened to their text.
class OpenclawWorkspace
  FILE_CAP = 20_000
  TOTAL_CAP = 60_000
  FILES = %w[SOUL.md AGENTS.md IDENTITY.md].freeze

  class Error < StandardError; end

  def initialize(soul, docs_root:)
    @soul = soul.to_s
    raise Error, "no soul named #{@soul.inspect}" unless @soul.match?(/\A[a-z0-9_-]+\z/)

    @dir = File.join(docs_root, @soul)
    raise Error, "no docs for #{@soul} at #{@dir}" unless File.directory?(@dir)
  end

  # { "SOUL.md" => text, "AGENTS.md" => text, "IDENTITY.md" => text }
  def files
    @files ||= begin
      built = {
        "SOUL.md" => compose(manifest.fetch("SOUL.md", ["soul.md"])),
        "AGENTS.md" => compose(manifest.fetch("AGENTS.md", ["role.md"])),
        "IDENTITY.md" => identity
      }
      check_caps!(built)
      built
    end
  end

  def write(out)
    FileUtils.mkdir_p(out)
    files.each { |name, text| File.write(File.join(out, name), text) }
    files.keys
  end

  private

  def manifest
    path = File.join(@dir, "openclaw.yml")
    @manifest ||= File.file?(path) ? YAML.safe_load_file(path) || {} : {}
  end

  def compose(names)
    Array(names).map do |name|
      path = File.join(@dir, name)
      raise Error, "#{@soul}: #{name} is named in openclaw.yml but does not exist" unless File.file?(path)

      flatten_links(File.read(path)).strip
    end.join("\n\n---\n\n") + "\n"
  end

  def identity
    name = manifest.fetch("name", @soul.split(/[-_]/).map(&:capitalize).join(" "))
    lines = [ "# #{name}", "", "- **Name:** #{name}" ]
    lines << "- **Emoji:** #{manifest['emoji']}" if manifest["emoji"]
    lines << "- **Vibe:** #{manifest['vibe']}" if manifest["vibe"]
    lines << "- **Source:** mcritchie-studio docs/agents/agents/#{@soul}/ (regenerate with bin/openclaw-workspace; do not edit here)"
    "#{lines.join("\n")}\n"
  end

  # [text](target) -> text, for any target that is not a web address.
  def flatten_links(text)
    text.gsub(/\[([^\]]+)\]\((?!https?:)[^)]*\)/, '\1')
  end

  def check_caps!(built)
    built.each do |name, text|
      raise Error, "#{@soul}: #{name} is #{text.length} characters; OpenClaw injects at most #{FILE_CAP}" if text.length > FILE_CAP
    end
    total = built.values.sum(&:length)
    raise Error, "#{@soul}: the workspace is #{total} characters; OpenClaw injects at most #{TOTAL_CAP}" if total > TOTAL_CAP
  end
end

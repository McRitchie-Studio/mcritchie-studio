# frozen_string_literal: true

require "optparse"

module EmailImages
  # bin/email-image — the agent's handle on email header briefs.
  #
  #   bin/email-image list
  #   bin/email-image brief --app turf-monster --email drop_signup_confirmation \
  #     --variant new_player --brand turf-monster --headline "You're In!" [--text-mode baked|none]
  #   bin/email-image generate <brief-slug> [--count 2]
  #   bin/email-image export <brief-slug> --into <dir-or-file> [--image-url <url>]
  #
  # Runs against the database this environment points at. `generate` enqueues
  # the same claimed, run-once job as the page's Generate button; it never
  # calls a vendor itself.
  class Cli
    USAGE = <<~TEXT
      usage: bin/email-image list
             bin/email-image brief --app <app> --email <key> [--variant <v>] --brand <kit> --headline "..." [--text-mode baked|none] [--format jpg|png] [--notes "..."]
             bin/email-image generate <brief-slug> [--count N]
             bin/email-image export <brief-slug> --into <dir-or-file> [--image-url <url>]
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    # Returns the exit status.
    def run
      command = @argv.shift
      case command
      when "list" then list
      when "brief" then brief
      when "generate" then generate
      when "export" then export
      else
        @err.puts USAGE
        command.nil? || %w[-h --help help].include?(command) ? 0 : 2
      end
    rescue OptionParser::ParseError, ArgumentError => e
      @err.puts "email-image: #{e.message}"
      @err.puts USAGE
      2
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
           EmailImages::Export::NotApproved, EmailImages::Export::ExportFailed, *EmailImages::Build::REFUSALS => e
      @err.puts "email-image: #{e.message}"
      1
    end

    private

    def list
      EmailImageBrief.ordered.each do |b|
        state = b.approved_artifact_slug.present? ? "approved" : (b.build_state || "new")
        @out.puts [b.slug, b.app, b.catalog_key, b.text_mode, state, "rounds #{b.rounds_used}/#{b.max_rounds}"].join("\t")
      end
      0
    end

    def brief
      opts = { text_mode: "baked", image_format: "jpg" }
      OptionParser.new do |o|
        o.on("--app APP") { |v| opts[:app] = v }
        o.on("--email KEY") { |v| opts[:email_key] = v }
        o.on("--variant V") { |v| opts[:variant] = v }
        o.on("--brand KIT") { |v| opts[:brand_kit] = v }
        o.on("--headline TEXT") { |v| opts[:headline] = v }
        o.on("--subtext TEXT") { |v| opts[:subtext] = v }
        o.on("--alt TEXT") { |v| opts[:alt_text] = v }
        o.on("--text-mode MODE") { |v| opts[:text_mode] = v }
        o.on("--format FMT") { |v| opts[:image_format] = v }
        o.on("--notes TEXT") { |v| opts[:prompt_notes] = v }
      end.parse!(@argv)
      record = EmailImageBrief.create!(opts.merge(created_by: "bin/email-image"))
      @out.puts "created #{record.slug}  (/email_images/#{record.slug})"
      0
    end

    def generate
      count = nil
      OptionParser.new { |o| o.on("--count N", Integer) { |v| count = v } }.parse!(@argv)
      record = find!(@argv.shift)
      EmailImages::Build.start!(record, count: count)
      @out.puts "#{EmailImages::Build::STARTED_NOTICE} (/email_images/#{record.slug})"
      0
    end

    def export
      into = nil
      image_url = nil
      OptionParser.new do |o|
        o.on("--into PATH") { |v| into = v }
        o.on("--image-url URL") { |v| image_url = v }
      end.parse!(@argv)
      raise ArgumentError, "--into is required" if into.blank?

      record = find!(@argv.shift)
      result = EmailImages::Export.call(record, into: into, image_url: image_url)
      @out.puts "wrote #{result.path} (#{result.bytesize} bytes)"
      @out.puts
      @out.puts result.snippet
      0
    end

    def find!(slug)
      raise ArgumentError, "name a brief slug" if slug.blank?

      EmailImageBrief.find_by!(slug: slug)
    end
  end
end

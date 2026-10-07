# frozen_string_literal: true

require "fileutils"
require "optparse"

module EmailImages
  # bin/email-image — the agent's handle on email header briefs, built so an
  # agent in a Claude Code session can run the whole `email-image` SOP
  # (docs/agents/agents/pokemon/sops/email-image.md) without the browser:
  # show Alex the brand's base assets, open a brief from his copy, generate a
  # round with his direction, show him the candidates, approve on his word,
  # export.
  #
  # OUTPUT IS ONE RECORD PER LINE: a record type, then tab-separated key=value
  # fields, so an agent can parse it and a person can still read it. Local file
  # paths are absolute. A data URI (the E2E fake's stand-in for a stored image)
  # prints as `url=inline` rather than flooding the terminal.
  #
  # Runs against the database this environment points at. On the production hub
  # (`heroku run -a mcritchie-studio bin/email-image …`) the downloads land on a
  # one-off dyno that is gone when the command ends, so every image also prints
  # its public URL for the agent to fetch locally.
  #
  # Exit status: 0 done, 1 refused or the round failed, 2 a usage error.
  class Cli
    USAGE = <<~TEXT
      usage: bin/email-image list
             bin/email-image assets <brand-kit> [--out <dir>] [--no-download]
             bin/email-image brief --app <app> --email <key> [--variant <v>] --brand <kit> --headline "..." [--subtext "..."] [--alt "..."] [--text-mode baked|none] [--format jpg|png] [--notes "..."] [--max-rounds N]
             bin/email-image brief <brief-slug> [--headline "..."] [--subtext "..."] [--alt "..."] [--text-mode baked|none] [--format jpg|png] [--notes "..."] [--max-rounds N]
             bin/email-image generate <brief-slug> [--notes "this round's direction"] [--count N] [--out <dir>] [--no-download]
             bin/email-image show <brief-slug> [--out <dir>] [--no-download]
             bin/email-image approve <brief-slug> <artifact-slug> --by <who>
             bin/email-image retire <brief-slug> <artifact-slug>
             bin/email-image export <brief-slug> --into <dir-or-file> [--image-url <url>]
    TEXT

    SCRATCH = "tmp/email-image"

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
      when "assets" then assets
      when "brief" then brief
      when "generate" then generate
      when "show" then show
      when "approve" then approve
      when "retire" then retire
      when "export" then export
      else
        @err.puts USAGE
        command.nil? || %w[-h --help help].include?(command) ? 0 : 2
      end
    rescue OptionParser::ParseError, ArgumentError => e
      @err.puts "email-image: #{e.message}"
      @err.puts USAGE
      2
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, EmailImages::BrandKit::UnknownKit,
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

    # THE BASE ASSETS, step 2 of the SOP: what the brand's headers are made from,
    # on disk so the agent can open each one and show Alex.
    def assets
      opts = download_options
      kit = EmailImages::BrandKit.find!(positional!("name a brand kit (#{EmailImages::BrandKit.keys.join(', ')})"))
      out_dir = opts[:out] || File.join(SCRATCH, kit.key)
      items = EmailImages::BaseAssets.call(kit, out: out_dir, download: opts[:download])

      emit "kit", kit.key, label: kit.label, app: kit.app, font: kit.font
      kit.palette.each { |name, hex| emit "palette", name, hex: hex }
      items.each do |item|
        emit item.kind, item.role, label: item.label, file: item.path || "-", url: printable(item.url),
                                   source: item.source
      end
      emit "style", nil, text: kit.style
      emit "never", nil, text: kit.negative
      0
    end

    # Opens a brief, or (given a slug first) edits one. The headline is the alt
    # text unless --alt says otherwise.
    def brief
      slug = @argv.first&.start_with?("-") ? nil : @argv.shift
      opts = {}
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
        o.on("--max-rounds N", Integer) { |v| opts[:max_rounds] = v }
      end.parse!(@argv)
      reject_extra_positionals!

      if slug
        fixed = opts.keys & %i[app email_key variant]
        raise ArgumentError, "a brief's app, email and variant are its identity; open a new brief instead" if fixed.any?
        raise ArgumentError, "nothing to change on #{slug}" if opts.empty?

        record = find!(slug)
        record.update!(opts)
        emit "updated", record.slug, **brief_fields(record)
      else
        record = EmailImageBrief.create!({ text_mode: "baked", image_format: "jpg" }.merge(opts)
                                                                                   .merge(created_by: "bin/email-image"))
        emit "created", record.slug, **brief_fields(record)
      end
      0
    end

    # ONE PAID ROUND, run in this process and waited for: the same refusals,
    # claim, round cap and cost record as the page's button (EmailImages::Build).
    def generate
      count = nil
      notes = nil
      opts = download_options do |o|
        o.on("--count N", Integer) { |v| count = v }
        o.on("--notes TEXT") { |v| notes = v }
      end
      record = find!(positional!("name a brief slug"))

      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      EmailImages::Build.run_now!(record, count: count, notes: notes)
      seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began).round(1)
      record.reload

      round = record.rounds_used
      made = record.candidates.select { |a| EmailImages::Prompt.round_of(a.prompt).round == round }
      units = made.sum { |a| a.billable_units.to_i }
      priced = made.map(&:cost_usd).compact
      emit "round", record.slug, round: "#{round}/#{record.max_rounds}", state: record.build_state,
                                 candidates: made.size, units: units, cost: priced.empty? ? "unpriced" : format("$%.4f", priced.sum),
                                 seconds: seconds, notes: EmailImages::Prompt.clean_notes(notes) || "-"
      made.reverse_each { |a| emit_candidate(record, a, opts) }

      if record.build_state == EmailImageBrief::FAILED
        @err.puts "email-image: round #{round} failed: #{record.build_error}"
        return 1
      end
      0
    end

    # Every candidate of a brief, oldest round first, with the round's notes.
    def show
      opts = download_options
      record = find!(positional!("name a brief slug"))
      emit "brief", record.slug, **brief_fields(record), spent: spend(record)
      record.candidates.to_a.reverse.each { |a| emit_candidate(record, a, opts) }
      0
    end

    # APPROVE ONLY ON ALEX'S WORD. --by names who said so and is stored as the
    # approver, so the record shows a person, not a script.
    def approve
      by = nil
      OptionParser.new { |o| o.on("--by WHO") { |v| by = v } }.parse!(@argv)
      record = find!(positional!("name a brief slug"))
      artifact = record.candidates.find_by!(slug: positional!("name the candidate's artifact slug"))
      reject_extra_positionals!
      if by.blank?
        raise ArgumentError, "--by is required: approve only on Alex's explicit word, and name him (--by alex)"
      end

      record.approve!(artifact, by: by.strip)
      emit "approved", record.slug, artifact: artifact.slug, by: by.strip, key: record.catalog_key
      0
    end

    def retire
      record = find!(positional!("name a brief slug"))
      artifact = record.candidates.find_by!(slug: positional!("name the candidate's artifact slug"))
      reject_extra_positionals!
      record.retire!(artifact)
      emit "retired", record.slug, artifact: artifact.slug, approved: record.approved_artifact_slug || "-"
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

    # --- helpers ---------------------------------------------------------

    def download_options
      opts = { download: true, out: nil }
      OptionParser.new do |o|
        o.on("--out DIR") { |v| opts[:out] = v }
        o.on("--no-download") { opts[:download] = false }
        yield o if block_given?
      end.parse!(@argv)
      opts
    end

    def emit_candidate(record, artifact, opts)
      line = EmailImages::Prompt.round_of(artifact.prompt)
      state = if record.approved_artifact_slug == artifact.slug then "approved"
              elsif artifact.retired? then "retired"
              else "live"
              end
      file = opts[:download] ? candidate_file(record, artifact, opts[:out]) : nil
      emit "candidate", artifact.slug, round: line.round || "-", state: state,
                                       cost: artifact.billing_summary || "-", file: file || "-",
                                       url: printable(artifact.image_url), notes: line.notes || "-"
    end

    # Downloads a candidate once; a file already on disk is reused.
    def candidate_file(record, artifact, out)
      dir = File.expand_path(out || File.join(SCRATCH, record.slug))
      existing = Dir.glob(File.join(dir, "#{artifact.slug}.*")).first
      return existing if existing

      bytes = EmailImages::Download.bytes(artifact.image_url)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{artifact.slug}.#{EmailImages::Download.extension_for(bytes)}")
      File.binwrite(path, bytes)
      path
    rescue EmailImages::Download::Failed => e
      @err.puts "email-image: could not download #{artifact.slug}: #{e.message}"
      nil
    end

    def brief_fields(record)
      { key: record.catalog_key, brand: record.brand_kit, text_mode: record.text_mode, format: record.image_format,
        rounds: "#{record.rounds_used}/#{record.max_rounds}", state: record.build_state || "new",
        approved: record.approved_artifact_slug || "-", headline: record.headline, alt: record.effective_alt_text,
        page: "/email_images/#{record.slug}" }
    end

    def spend(record)
      cost = record.cost_usd_total
      "#{record.billable_units_total} units#{cost ? format(' $%.4f', cost) : ' unpriced'}"
    end

    def printable(url)
      return "-" if url.blank?

      url.to_s.start_with?("data:") ? "inline" : url
    end

    # type, an optional subject, then key=value fields; tabs and newlines in a
    # value are flattened so one record stays one line.
    def emit(type, subject, **fields)
      parts = [type]
      parts << subject.to_s if subject
      fields.each { |k, v| parts << "#{k}=#{v.to_s.gsub(/[\t\r\n]+/, ' ')}" }
      @out.puts parts.join("\t")
    end

    def positional!(missing)
      value = @argv.shift
      raise ArgumentError, missing if value.blank? || value.start_with?("-")

      value
    end

    def reject_extra_positionals!
      raise ArgumentError, "unexpected #{@argv.map(&:inspect).join(' ')}" if @argv.any?
    end

    def find!(slug)
      raise ArgumentError, "name a brief slug" if slug.blank?

      EmailImageBrief.find_by!(slug: slug)
    end
  end
end

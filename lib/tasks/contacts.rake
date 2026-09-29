require "csv"

namespace :contacts do
  # Import contacts from a HubSpot CSV export.
  #   bin/rails "contacts:import[/path/to/hubspot-export.csv,subscribers]"
  # Expects headers including Email / First Name / Last Name (HubSpot defaults).
  # The optional 2nd arg tags every imported contact (e.g. "subscribers").
  desc "Import contacts from a CSV (email, first name, last name)"
  task :import, %i[path tag] => :environment do |_t, args|
    abort "Usage: contacts:import[path.csv,tag]" if args[:path].blank?
    tag = args[:tag].presence

    created = updated = skipped = 0
    CSV.foreach(args[:path], headers: true) do |row|
      h = row.to_h.transform_keys { |k| k.to_s.strip.downcase }
      email = h["email"].to_s.strip
      next (skipped += 1) if email.blank?

      c = Contact.find_or_initialize_by(email: email.downcase)
      was_new = c.new_record?
      c.first_name = h["first name"].presence || h["first_name"].presence || c.first_name
      c.last_name  = h["last name"].presence  || h["last_name"].presence  || c.last_name
      c.source   ||= "csv_import"
      c.tags = (c.tags + [tag]).uniq if tag
      c.save!
      was_new ? created += 1 : updated += 1
    end

    puts "Imported: #{created} new, #{updated} updated, #{skipped} skipped."
  end

  # Verify a list's contacts with ZeroBounce, most recently active first (task
  # verify-contacts-with-zerobounce). See Contacts::Verification.
  #
  #   bin/rails "contacts:verify[10000,/tmp/cyvasse-last-active.csv]"
  #
  # source_csv: `email,last_active_at` rows ranking who goes first (built on
  #   the cyvasse app by script/contacts/cyvasse_last_active.rb). Optional; a
  #   contact it does not name goes last.
  # DRY_RUN=1   pick and report only: nothing submitted, nothing written.
  # FILE_ID=…   resume a submitted file (poll, download, apply); submits nothing.
  # AUDIENCE    the tag to verify (default cyvasse-legacy).
  # BROADCAST   skip contacts this broadcast already reached (default
  #             cyvasse-is-back when it exists; "none" to skip nobody).
  # Needs ZEROBOUNCE_API_KEY (a dry run without one just skips the balance).
  desc "Verify list contacts with ZeroBounce, most recently active first"
  task :verify, %i[limit source_csv] => :environment do |_t, args|
    abort "Usage: contacts:verify[limit,source_csv] (DRY_RUN=1, FILE_ID=…)" if args[:limit].blank?

    dry_run = ENV["DRY_RUN"].to_s == "1"
    audience = ENV["AUDIENCE"].presence || "cyvasse-legacy"
    broadcast = case ENV["BROADCAST"].presence
                when "none" then nil
                when nil then Broadcast.find_by(slug: "cyvasse-is-back")
                else Broadcast.find_by!(slug: ENV["BROADCAST"])
                end

    recency = {}
    if args[:source_csv].present?
      recency = File.open(args[:source_csv]) { |f| Contacts::Verification.read_recency(f) }
      abort "#{args[:source_csv]} has no email,last_active_at rows" if recency.empty?
    end

    client = Contacts::ZeroBounce.from_env if ENV["ZEROBOUNCE_API_KEY"].present? || !dry_run
    verification = Contacts::Verification.new(client: client, limit: args[:limit], audience: audience,
                                              broadcast: broadcast, recency: recency, dry_run: dry_run,
                                              file_id: ENV["FILE_ID"])
    begin
      s = verification.run
    rescue StandardError => e
      ErrorLog.capture!(e)
      abort "contacts:verify: #{e.class}: #{e.message}\n" \
            "If a line above says it submitted a file, resume with FILE_ID=<that id>; never rerun without it."
    end

    puts "#{"DRY RUN: " if s.dry_run}#{audience}#{" minus #{broadcast.slug} recipients" if broadcast}: " \
         "#{s.candidates} unverified candidates, #{s.picked} picked (#{s.ranked} ranked by the CSV of #{recency.size})"
    puts "picked activity: newest #{s.newest&.to_date || "-"}, oldest #{s.oldest&.to_date || "-"}" if s.picked.positive?
    puts "credits: #{s.credits_before || "not read (no ZEROBOUNCE_API_KEY)"}#{" -> #{s.credits_after}" if s.credits_after}"
    if s.dry_run
      short = s.credits_before && s.credits_before < s.picked
      puts "a real run would submit #{s.picked}#{" and REFUSE: only #{s.credits_before} credits" if short}"
    else
      puts "file #{s.file_id || "-"}: #{s.counts.sort.map { |k, v| "#{k} #{v}" }.join(", ").presence || "no results"}"
      puts "unsubscribed (verification): #{s.unsubscribed}; picked but unanswered: #{s.missing}"
    end
  end
end

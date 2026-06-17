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
end

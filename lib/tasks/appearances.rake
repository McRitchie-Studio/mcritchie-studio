namespace :appearances do
  # THE OPERATOR'S HANDS ON THE CHARACTER-IDENTITY LANE.
  #
  # NO "NEXT ONE" DEFAULT, unlike the content tasks beside it. Every call to
  # Higgsfield costs real money, and a task that picks its own subject makes a
  # mistyped invocation a purchase. The slug is required, always.
  desc "Mint a Higgsfield character identity for one look — SLUG=look-xxx [FORCE=1]"
  task character_reference: :environment do
    slug = ENV["SLUG"].presence or raise "SLUG=look-xxx is required (this spends money; it will not guess)"
    look = Appearance.find_by!(slug: slug)
    # EXACTLY "1". `FORCE=0` is a refusal, and `.present?` granted it — buying a
    # second identity and orphaning the first beyond recall (there is no list).
    force = ENV["FORCE"] == "1"

    # Printed BEFORE the call, because after it the money is gone. The operator
    # sees exactly which photographs the identity would be built from.
    #
    # THROUGH ReferenceSet, NOT ReferenceImages. The set is the floor PLUS the
    # chosen search hits, which is what the create below is now injected with —
    # printing the floor alone would have shown the operator a shorter list than
    # the one they were about to pay for.
    images = Appearances::ReferenceSet.call(look)
    puts "Look:   #{look.slug} — #{look.person_slug} / #{look.descriptor}"
    puts "Images: #{images.length}"
    images.each { |url| puts "  #{url}" }

    if look.higgsfield_reference_id.present? && !force
      puts "Already has #{look.higgsfield_reference_id} (#{look.higgsfield_reference_status}) — pass FORCE=1 to rebuild"
      next
    end

    id = Appearances::CreateCharacterReference
         .new(look, references: Appearances::ReferenceSet).call(force: force)
    puts "Identity: #{id} (#{look.reload.higgsfield_reference_status})"
    puts "It is NOT usable yet — run appearances:refresh_character_references until it reads " \
         "#{Appearances::CreateCharacterReference::READY_STATUS}"
  end

  # WHAT STOPS THE STORED STATUS BEING A LIE. A create stamps `not_ready` and
  # nothing else moves it, so without a poll the column that answers "may we pin
  # a generation to this yet?" answers no forever. Reads only — free.
  desc "Poll every identity still becoming ready and record where it got to"
  task refresh_character_references: :environment do
    pending = Appearance.where.not(higgsfield_reference_id: nil)
                        .where(higgsfield_reference_status: Appearances::CreateCharacterReference::PENDING_STATUSES)

    if pending.empty?
      puts "Nothing pending."
      next
    end

    pending.find_each do |look|
      status = Appearances::CreateCharacterReference.new(look).refresh_status!
      puts "#{look.slug}  #{look.higgsfield_reference_id}  -> #{status}"
    rescue StandardError => e
      # One unreachable identity must not strand the rest of the sweep.
      puts "#{look.slug}  #{look.higgsfield_reference_id}  -> ERROR #{e.class}: #{e.message}"
    end
  end

  # FIND PHOTOGRAPHS FOR ONE LOOK. Spends one image-search query.
  #
  # SLUG IS REQUIRED for the same reason the mint task requires it: this is a
  # purchase, and a task that picks its own subject makes a mistyped invocation a
  # purchase of the wrong thing.
  #
  # With no provider configured this reports that and files nothing — it is not an
  # error, it is the state the machine is in until a credential lands.
  desc "Search the web for reference photos for one look — SLUG=look-xxx"
  task search_reference_photos: :environment do
    slug = ENV["SLUG"].presence or raise "SLUG=look-xxx is required (this spends money; it will not guess)"
    look = Appearance.find_by!(slug: slug)

    summary = Appearances::GatherReferencePhotos.call(look)
    unless summary.configured?
      puts "No image-search provider configured — set " \
           "#{Appearances::ImageSearch::Serper::API_KEY_ENV}. Nothing searched, nothing spent."
      next
    end

    puts "Query:      #{summary.query}"
    puts "Provider:   #{summary.provider_name}"
    puts "Returned:   #{summary.returned}"
    puts "Unreadable: #{summary.unparsed}   (a non-zero count here is a PARSER bug, not an empty search)"
    puts "Unsafe:     #{summary.unfetchable}"
    puts "Filed:      #{summary.filed}  (#{summary.chosen} chosen, #{summary.rejected} kept as rejects)"
    puts
    puts "The model would now be built from:"
    Appearances::ReferenceSet.call(look.reload).each { |url| puts "  #{url}" }
  end
end

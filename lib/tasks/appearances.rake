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
    force = ENV["FORCE"].present?

    # Printed BEFORE the call, because after it the money is gone. The operator
    # sees exactly which photographs the identity would be built from.
    images = Appearances::ReferenceImages.call(look)
    puts "Look:   #{look.slug} — #{look.person_slug} / #{look.descriptor}"
    puts "Images: #{images.length}"
    images.each { |url| puts "  #{url}" }

    if look.higgsfield_reference_id.present? && !force
      puts "Already has #{look.higgsfield_reference_id} (#{look.higgsfield_reference_status}) — pass FORCE=1 to rebuild"
      next
    end

    id = Appearances::CreateCharacterReference.new(look).call(force: force)
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
end

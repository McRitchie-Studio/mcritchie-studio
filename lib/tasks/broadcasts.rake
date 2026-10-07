namespace :broadcasts do
  # The relaunch note's subject, and the one it replaced (a draft still carrying
  # the old default is moved to the new one; an edited subject is left alone).
  CYVASSE_IS_BACK_SUBJECT = "\u{1F409} Cyvasse is back \u2014 now with live matches".freeze
  CYVASSE_IS_BACK_OLD_SUBJECTS = [ "Cyvasse is back" ].freeze

  desc "Publish broadcast email images (public/email/*) to S3 for use in sent emails"
  task publish_assets: :environment do
    # The release runs a task's post-deploy on QA before production, and QA has
    # no AWS credentials or bucket. Sent email only ever uses production's
    # copies, so QA has nothing to publish (task publish-assets-skips-qa).
    if Studio.qa_environment?
      puts "QA: skipping broadcast asset publish (sent email uses production's copies)"
      next
    end

    urls = Broadcasts::Assets.publish_all!
    if urls.empty?
      puts "No images found in #{Broadcasts::Assets::SOURCE_DIR}"
    else
      puts "Published #{urls.size} asset(s) to #{Broadcasts::Assets.base_url}:"
      urls.each { |name, url| puts "  #{name} -> #{url}" }
    end
  end

  # The "Cyvasse is back" relaunch note (task cyvasse-is-back-outreach), as a
  # DRAFT at /broadcasts/cyvasse-is-back/edit. Idempotent: an existing row is
  # left as it is, so edits made in the editor survive a re-run. It never sends.
  desc "Create the Cyvasse Is Back broadcast as a draft (never sends)"
  task draft_cyvasse_is_back: :environment do
    broadcast = Broadcast.find_or_create_by!(slug: "cyvasse-is-back") do |b|
      b.template_key = "cyvasse_is_back"
      b.subject      = CYVASSE_IS_BACK_SUBJECT
      b.target_list  = "cyvasse-legacy"
      b.status       = "draft"
    end
    puts "#{broadcast.slug}: #{broadcast.status} (#{broadcast.template_label}) -> /broadcasts/#{broadcast.slug}/edit"
  end

  # The play-times note (task cyvasse-play-times-email), as a DRAFT at
  # /broadcasts/cyvasse-play-times/edit, on the legacy list. Idempotent: an
  # existing row is left as it is, so editor edits survive a re-run (it runs
  # as the task's post-deploy). It never stages or sends.
  desc "Create the Cyvasse Play Times broadcast as a draft (never sends)"
  task draft_cyvasse_play_times: :environment do
    broadcast = Broadcast.find_or_create_by!(slug: "cyvasse-play-times") do |b|
      b.template_key = "cyvasse_play_times"
      b.subject      = Broadcasts::CyvassePlayTimes::PLAIN_SUBJECT
      b.target_list  = "cyvasse-legacy"
      b.status       = "draft"
    end
    puts "#{broadcast.slug}: #{broadcast.status} (#{broadcast.template_label}) -> /broadcasts/#{broadcast.slug}/edit"
  end

  # Post-deploy for task cyvasse-email-live-copy: moves the existing draft to
  # the new subject. Idempotent; never touches a sent broadcast or a subject
  # someone edited in the editor, and never sends.
  desc "Refresh the Cyvasse Is Back draft's subject to the live-matches one"
  task refresh_cyvasse_is_back: :environment do
    broadcast = Broadcast.find_by(slug: "cyvasse-is-back")
    if broadcast.nil?
      puts "cyvasse-is-back: no row (run broadcasts:draft_cyvasse_is_back)"
    elsif broadcast.status != "draft" || broadcast.sent_at.present?
      puts "cyvasse-is-back: #{broadcast.status}, left as it is"
    elsif CYVASSE_IS_BACK_OLD_SUBJECTS.include?(broadcast.subject)
      broadcast.update!(subject: CYVASSE_IS_BACK_SUBJECT)
      puts "cyvasse-is-back: subject -> #{broadcast.subject}"
    else
      puts "cyvasse-is-back: subject already #{broadcast.subject.inspect}, left as it is"
    end
    overrides = %w[header subheader preview_text].select { |f| broadcast&.public_send(f).present? }
    puts "cyvasse-is-back: editor overrides in use: #{overrides.join(", ")}" if overrides.any?
  end
end

namespace :broadcasts do
  desc "Publish broadcast email images (public/email/*) to S3 for use in sent emails"
  task publish_assets: :environment do
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
      b.subject      = "Cyvasse is back"
      b.target_list  = "cyvasse-legacy"
      b.status       = "draft"
    end
    puts "#{broadcast.slug}: #{broadcast.status} (#{broadcast.template_label}) -> /broadcasts/#{broadcast.slug}/edit"
  end
end

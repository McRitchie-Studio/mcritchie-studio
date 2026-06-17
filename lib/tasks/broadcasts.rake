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
end

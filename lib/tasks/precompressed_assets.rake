# Gzip sidecars for the compiled stylesheets, scripts and SVGs: see
# lib/precompressed_assets.rb. Propshaft writes none; Sprockets did, and the
# production stack depends on them (config/application.rb, Rack::Deflater).
namespace :assets do
  desc "Write .gz sidecars beside the precompiled css, js and svg"
  task precompress: :environment do
    written = PrecompressedAssets.new(Rails.application.config.assets.output_path).write!
    puts "precompressed assets: #{written.size} .gz written"
  end
end

if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance { Rake::Task["assets:precompress"].invoke }
end
# assets:clean deletes old digests; drop their sidecars with them.
if Rake::Task.task_defined?("assets:clean")
  Rake::Task["assets:clean"].enhance do
    PrecompressedAssets.new(Rails.application.config.assets.output_path).prune!
  end
end

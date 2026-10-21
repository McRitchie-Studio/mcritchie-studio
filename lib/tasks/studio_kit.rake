# The Studio kit for client apps (ClientApps::StudioKit::Css,
# docs/agents/system/client-app-host.md "The Studio template"): compiled from the
# engine's CSS by the hub's Tailwind into tmp/studio_kit/<digest>.css, so a
# dyno serves it without compiling on its first client-app request. A process
# that finds no file for the current inputs compiles it then, so this is a
# warm-up, never a requirement.
namespace :studio_kit do
  desc "Compile the Studio kit's CSS for client apps from studio-engine"
  task build: :environment do
    path = ClientApps::StudioKit::Css.output_path
    ClientApps::StudioKit::Css.build!(path)
    puts "studio kit #{ClientApps::StudioKit.version}: #{path.relative_path_from(Rails.root)} (#{path.size} bytes)"
  end
end

Rake::Task["assets:precompile"].enhance { Rake::Task["studio_kit:build"].invoke } if Rake::Task.task_defined?("assets:precompile")

# The Studio kit for client apps (ClientApps::StudioKit::Css,
# docs/agents/system/client-app-host.md "The Studio template"): compiled from the
# engine's CSS by the hub's Tailwind into app/assets/builds/studio_kit/<digest>.css.
#
# A PREREQUISITE of assets:precompile, so the Heroku build (which runs
# `rake assets:precompile`) writes it into the slug, and the dynos read it
# instead of compiling. The digest is content-only, so the build directory and
# the running slug name the same file. A process that finds no file still
# compiles it once on first use, so this is a warm-up, never a requirement.
namespace :studio_kit do
  desc "Compile the Studio kit's CSS for client apps from studio-engine"
  task build: :environment do
    path = ClientApps::StudioKit::Css.output_path
    ClientApps::StudioKit::Css.build!(path)
    puts "studio kit: #{path.relative_path_from(Rails.root)} (#{path.size} bytes)"
  end
end

Rake::Task["assets:precompile"].enhance([ "studio_kit:build" ]) if Rake::Task.task_defined?("assets:precompile")

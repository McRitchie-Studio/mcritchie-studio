# frozen_string_literal: true

require "pathname"

# Links studio-engine's Node tooling package into this checkout, safely
# (`bin/rails node_tooling:link`). The engine's own `studio:node:link` writes
# `node_modules/.studio-engine` -> the gem's directory; this wraps it with the
# two places in this ecosystem where that write lands somewhere it should not:
#
# 1. A SHARED node_modules. Some desks symlink node_modules to the primary
#    checkout's, so a link written "here" is written into the primary, pointing
#    at whatever gem the desk resolved. When the shared directory already holds a
#    link to the gem this checkout bundles, there is nothing to do. When it does
#    not, refuse and name the checkout that owns the directory: link there, or
#    give this desk a node_modules of its own (`npm ci`).
# 2. HEROKU. The link holds an absolute gem path, which is a build-machine path
#    in a build phase and /app/... on a dyno. Nothing on Heroku runs Playwright or
#    node:test, so a link there is never needed and always wrong: refuse.
#
# Returns [status, message]: :linked, :shared (already right), or :refused.
module NodeToolingLink
  module_function

  def call(root:, tooling:, env: ENV)
    root = Pathname(root)
    if heroku?(env)
      return [:refused, "refusing to link on Heroku (DYNO/STACK set): the link would hold a build-machine gem path, " \
                        "and nothing on a dyno runs Playwright or node:test"]
    end

    node_modules = root.join("node_modules")
    return shared(node_modules, tooling) if node_modules.symlink?

    path = tooling.link!(root)
    [:linked, "#{path.relative_path_from(root)} -> #{tooling.root}"]
  end

  def heroku?(env)
    !env["DYNO"].to_s.empty? || env["STACK"].to_s.start_with?("heroku")
  end

  def shared(node_modules, tooling)
    owner = node_modules.realpath.dirname
    link = node_modules.join(File.basename(tooling::LINK))
    if link.symlink? && link.readlink == tooling.root
      return [:shared, "node_modules is shared with #{owner}, whose link already points at #{tooling.root}"]
    end

    found = link.symlink? ? link.readlink.to_s : "no link"
    [:refused, "node_modules is a symlink to #{node_modules.realpath}, so linking here would write #{owner}'s link " \
               "(it has #{found}; this checkout bundles #{tooling.root}). Run `bin/rails node_tooling:link` in #{owner} " \
               "when it bundles the same studio-engine, or replace this desk's node_modules symlink with its own `npm ci`."]
  rescue Errno::ENOENT
    [:refused, "node_modules is a dangling symlink (#{node_modules.readlink}); remove it and run `npm ci`"]
  end
end

# frozen_string_literal: true

module ClientApps
  module StudioKit
    # Renders the kit's markup from the hub's and the engine's views, outside any
    # request: a bare controller with no route, no session and no layout, so no
    # hub cookie, path or helper state can reach a client app's page.
    module Renderer
      # The render context. Its own helper overrides the one engine helper that
      # would reach for hub config: the booking popup (Studio.booking_url is the
      # hub's own calendar, and its dialog loads Google's frame).
      class Controller < ActionController::Base
        module KitHelper
          def studio_booking? = false
        end

        helper KitHelper
      end

      module_function

      # Every comment is dropped: a partial's comments (and development's
      # template-path annotations) are page content on a client's app.
      def render(partial, **locals)
        Controller.render(partial: partial, locals: locals).to_s.gsub(/<!--.*?-->/m, "")
      end

      def navbar(identity, toggle) = render("client_apps/kit/navbar", identity: identity, toggle: toggle)

      # The engine's site footer, with facts for the app: its name (the
      # engine's wordmark split), and one column back to the Studio. Marked
      # data-studio-footer so the kit's CSS can tell it from an older bundle's
      # own footer.
      def footer(identity)
        facts = Studio::SiteFooter.resolve(footer_facts(identity), nil)
        html = render("studio/site_footer/footer", facts: facts)
        html = html.gsub(%r{<style[^>]*>.*?</style>}m, "") # the CSS rides in the kit file
        html.sub("<footer ", "<footer data-studio-footer ").strip
      end

      def footer_facts(identity)
        { name: identity.name,
          home_path: "/",
          columns: [ { heading: "McRitchie Studio",
                       links: [ [ "Built with McRitchie Studio", StudioKit::STUDIO_URL ],
                                [ "Build your own app", "#{StudioKit::STUDIO_URL}/build" ] ] } ] }
      end

      def engine_toggle = render("components/theme_toggle")

      def engine_footer_assets = render("studio/site_footer/assets")
    end
  end
end

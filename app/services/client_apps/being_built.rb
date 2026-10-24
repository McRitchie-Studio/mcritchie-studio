# frozen_string_literal: true

module ClientApps
  # What the "being built" page wears for a sub with no bundle yet
  # (ClientApps::Host): the app's name, its CTO, and its colours. Every field was
  # written by the client at /build, so Pages escapes the text and takes only
  # #RRGGBB colours and a known portrait key.
  BeingBuilt = Struct.new(:name, :cto_name, :portrait, :light, :dark, keyword_init: true) do
    # For SUB: a client app (an App with a CTO), else a /build request holding
    # the name (an admin's showcase queued without the checklist has no App).
    # nil when neither, which the host answers with a 404.
    def self.for(sub, app)
      cto = app&.client_cto
      return from_app(app, cto) if cto

      request = AppRequest.holding.where(subdomain: sub).order(id: :desc).first
      request ? from_request(request) : nil
    end

    def self.from_app(app, cto)
      palette = AppPalette.valid?(cto.palette) ? cto.palette : app.theme_colors
      new(name: app.name, cto_name: cto.name, portrait: cto.portrait, light: AppPalette.side(palette, "light"),
          dark: AppPalette.side(palette, "dark"))
    end

    def self.from_request(request)
      new(name: request.working_title || request.subdomain, cto_name: request.cto_name, portrait: request.cto_avatar,
          light: AppPalette.side(request.palette, "light"), dark: AppPalette.side(request.palette, "dark"))
    end

    # The portrait's SVG bytes when it names an animal (drawn in the app's
    # palette, light and dark by the visitor's scheme: BuildIntake::Animals
    # .document) or a default portrait, else nil (an upload ref, or nothing):
    # the page then shows the CTO's initial.
    def portrait_svg
      key = portrait.to_s
      if BuildIntake::Animals.avatar?(key)
        return BuildIntake::Animals.document(key, { "light" => light, "dark" => dark })
      end
      return nil unless BuildIntake::Portraits.key?(key)

      path = Rails.root.join("app/assets/images/cto_portraits/#{key}.svg")
      path.file? ? path.binread : nil
    end
  end
end

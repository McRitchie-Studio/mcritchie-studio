module StackHelper
  # A client's own logo (ClientLogo) in a `px`-square box: a logo-studio brand's kit icon in the hub theme's tone
  # (LogosHelper#logo_themed_images, as /logos draws it), or the mark filed in the hub's brand assets. A client with no
  # logo gets the empty ring, so the column still lines up.
  def client_logo(logo, px:, name:)
    box = "inline-flex shrink-0 items-center justify-center"
    style = "width: #{px}px; height: #{px}px"
    return tag.span(class: "#{box} rounded-full border-2 border-dashed border-subtle", style:, aria: { hidden: true }, data: { test: "client-logo-missing" }) unless logo

    picture = if logo.source == :brand
                logo_themed_images(logo.variants, height: px)
              else
                image_tag logo.file, alt: "", class: "block max-w-full max-h-full w-auto h-auto"
              end
    tag.span(picture, class: box, style:, title: name, data: { test: "client-logo", source: logo.source, client: logo.slug })
  end
end

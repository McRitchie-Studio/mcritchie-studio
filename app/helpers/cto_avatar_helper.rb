# The CTO's avatar wherever it shows (the /build agent card and status tile, the
# summary, the launch panel, the CTO chat head): an animal from the bank
# ("animal:<id>", BuildIntake::Animals) drawn inline in the app's PALETTE, or one
# of the older portrait keys (BuildIntake::Portraits) as its image, so an app
# that chose a portrait keeps it. nil for anything else (an upload ref, nothing).
module CtoAvatarHelper
  def cto_avatar_tag(avatar, palette, css_class: nil, label: nil, data: {})
    if BuildIntake::Animals.avatar?(avatar)
      # Safe: every interpolated value in the markup is escaped or ours (the glyph file).
      BuildIntake::Animals.inline_svg(avatar, palette, css_class: css_class, label: label, data: data).html_safe
    elsif BuildIntake::Portraits.key?(avatar)
      image_tag BuildIntake::Portraits.path(avatar), alt: label.to_s, class: css_class, data: data
    end
  end

  # One set for the picker: PICKED leads it (an animal, or an older portrait
  # key a draft or app already holds, so a re-save never loses it), then
  # animals from the bank, none repeated, none from EXCEPT while enough remain.
  def cto_avatar_set(picked, seed: nil, except: [])
    size = BuildIntake::Animals::SET_SIZE
    return [ picked ] + BuildIntake::Animals.sample(size: size - 1, except: except, seed: seed) if BuildIntake::Portraits.key?(picked)

    BuildIntake::Animals.sample(size: size, keep: picked, except: except, seed: seed)
  end

  # The avatar's name for a screen reader: "Fox", or a portrait's "Harbor".
  def cto_avatar_label(avatar)
    BuildIntake::Animals.avatar?(avatar) ? BuildIntake::Animals.label(avatar) : BuildIntake::Portraits.label(avatar)
  end
end

# THE DEFAULT-LOOK POINTER, shared by every owner of looks (Person, Character).
#
# One rule, one home: a Character's default look resolves and releases exactly
# the way a Person's always has, because both call this method and Appearance's
# callbacks call it on whichever owner the look has.
#
# The includer supplies `has_many :appearances` and a `default_appearance_slug`
# column.
module HoldsDefaultAppearance
  extend ActiveSupport::Concern

  # RE-RESOLVE THE DEFAULT POINTER AGAINST REALITY.
  #
  # `default_appearance_slug` is a plain string column with NO foreign key, and
  # for a long time exactly one callback wrote it — an after_CREATE. So every
  # transition that is not a create left it describing a world that had moved:
  # destroy the look it names and the column still names it, so
  # #default_appearance returns nil while the owner plainly has looks, and
  # because Appearance#become_default_if_first only ever fired on a BLANK
  # pointer, nothing could refill it. "Has looks, resolves no default" was
  # permanent, and had nothing to grep for.
  #
  # Keeps a pointer that still names a LIVE look, otherwise takes the oldest
  # live look, otherwise blanks the column. Returns the slug it settled on.
  #
  # Writes with update_columns deliberately: this is pointer hygiene run from
  # inside other records' callbacks (a look being destroyed, a merge handing
  # looks to a survivor), and it must not re-enter validation or bump
  # updated_at on an owner nobody edited.
  def resolve_default_appearance!
    current = default_appearance_slug
    return current if current.present? && appearances.live.exists?(slug: current)

    settled = appearances.live.order(:created_at, :id).first&.slug
    update_columns(default_appearance_slug: settled) if persisted? && !destroyed?
    self.default_appearance_slug = settled
    settled
  end
end

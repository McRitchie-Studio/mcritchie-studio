# A slug column whose writers pass whatever handle the caller holds (a mascot, an
# SOP name, a task not yet created), on a table whose writes must never fail on
# it: telemetry, task notes, the desk inventory. The column carries a foreign key,
# so a slug no parent row holds would raise. Before validation, a slug that names
# no row becomes the row it differs from only by case, or else NULL; with
# `keep_in:`, the handle first moves into that JSON column under `as:`.
#
#   clears_unknown_slug :agent_slug, "Agent", keep_in: :metadata, as: "agent_handle"
#
# The check runs only when the column changes, one indexed lookup per write.
module ClearsUnknownSlug
  extend ActiveSupport::Concern

  class_methods do
    def clears_unknown_slug(column, parent, keep_in: nil, as: nil)
      before_validation do
        value = self[column]
        next if value.blank? || !will_save_change_to_attribute?(column)

        parent_class = parent.constantize
        next if parent_class.exists?(slug: value)

        cased = value.to_s.strip.downcase
        if cased != value && parent_class.exists?(slug: cased)
          self[column] = cased
          next
        end

        self[keep_in] = (self[keep_in] || {}).merge(as => value) if keep_in
        self[column] = nil
      end
    end
  end
end

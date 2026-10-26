# frozen_string_literal: true

# Where a /build sign-up came from (Avi's alex-build-funnel-handoff, folded into
# ritch-renamed-alex): `alex.build` when the visitor arrived from alex.build's
# CTAs (a `ref` or `utm_source` naming it, or an alex.build referrer), else nil.
# A plain nullable string: one known value today, read by the /build/requests
# list and by any funnel count. AppRequest::ORIGINS is the vocabulary.
class AddOriginToAppRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :app_requests, :origin, :string
  end
end

# frozen_string_literal: true

# Two changes to /build requests.
#
# SHOWCASE — Mr. McRitchie is seeding the App Builder with his own legacy apps as
# example builds, submitted through the real funnel. Admins are exempt from the
# one-free-app rule, and their requests carry `showcase`, so the board, the
# requests list and the Discord post keep them apart from customer requests.
#
# THE NAME INDEX — the unique index on `subdomain` covered EVERY row with one, so
# a cancelled request kept its name forever, while the model (HOLDING) says a
# cancelled request frees it. The index now covers only the statuses that hold a
# name, so the database and the model agree.
class AppRequestShowcaseAndHoldingIndex < ActiveRecord::Migration[8.1]
  def change
    add_column :app_requests, :showcase, :boolean, null: false, default: false

    remove_index :app_requests, :subdomain, unique: true, where: "subdomain IS NOT NULL",
                                            name: "index_app_requests_on_subdomain"
    add_index :app_requests, :subdomain, unique: true,
              where: "subdomain IS NOT NULL AND status IN ('queued', 'building', 'live')",
              name: "index_app_requests_on_holding_subdomain"
  end
end

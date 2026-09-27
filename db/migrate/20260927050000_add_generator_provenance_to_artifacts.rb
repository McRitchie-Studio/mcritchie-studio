# frozen_string_literal: true

# WHICH GENERATOR MADE THIS PICTURE, AND WHICH VERSION OF IT.
#
# The operator's decision, 2026-09-26: "the generator should be data driven to an
# extent and deterministic. We should be able to transition between generators as
# model capacities change." The transition is the reason these columns exist. A
# library that will hold images from SEVERAL generators is unreadable without a
# stamp on each one: you cannot tell a model regression from a provider change,
# and "the sheets got worse in March" has no way to become a question anyone can
# answer.
#
# WHY NOT `artifacts.source`. That column already exists and is the obvious
# candidate. It is one free-text string, and this needs four facts that get asked
# DIFFERENT questions — "show me everything fal made" (generator), "did the
# endpoint move" (generator_endpoint), "which contract did we read it off"
# (generator_version), "reproduce this exact frame" (seed + prompt). Packing them
# into one string makes every one of those a LIKE query against a format nobody
# declared. `source` keeps its meaning: where the bytes came from.
#
# ALL NULLABLE, because every artifact already on file predates this and none of
# them can be back-stamped honestly. A NULL generator means "made before we
# recorded it", which is a true statement; a default of "higgsfield" would be a
# guess written into the record as a fact.
#
# SEED AND PROMPT ARE THE OTHER HALF OF DETERMINISM. Pinning the model version
# says WHICH model ran; the seed says which draw, and the prompt says what it was
# asked for. A sheet from March matches one from January only if all three are
# recoverable, and the prompt is derived at call time from Appearance#generation_brief
# — so unless it is stored here, re-running the same sheet after any edit to the
# look silently generates something else.
#
# `cost_usd` IS NULLABLE FOR A REASON THAT IS NOT LAZINESS. Not every vendor
# reports what a call cost on the call itself. NULL means "not reported", never
# "free", and the page renders it as the former.
class AddGeneratorProvenanceToArtifacts < ActiveRecord::Migration[8.1]
  def change
    add_column :artifacts, :generator, :string
    add_column :artifacts, :generator_endpoint, :string
    add_column :artifacts, :generator_version, :string
    add_column :artifacts, :seed, :bigint
    add_column :artifacts, :prompt, :text
    add_column :artifacts, :cost_usd, :decimal, precision: 10, scale: 4

    # THE MEASURED QUANTITY, KEPT BESIDE THE DERIVED PRICE.
    #
    # `x-fal-billable-units` is what the vendor ACTUALLY reported on the call
    # (measured 2026-09-26: one BALANCED image billed 3 units). `cost_usd` is
    # that number multiplied by a rate this repo declares. Keeping both means a
    # rate correction re-prices the whole back-catalogue arithmetically, instead
    # of leaving a library of dollar figures nobody can re-derive.
    add_column :artifacts, :billable_units, :integer

    # THE ONE QUERY THIS TABLE WILL BE ASKED AS SOON AS A SECOND GENERATOR EXISTS:
    # "show me the live images this generator made". Partial, because the
    # back-catalogue is all NULL and indexing it buys nothing.
    add_index :artifacts, [:generator, :retired_at],
              where: "generator IS NOT NULL",
              name: "index_artifacts_on_generator_and_retired_at"
  end
end

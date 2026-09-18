# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Replaces the list of a "Participants from a file" census with the
        # rows of a mapped CSV.
        #
        # All or nothing: a census is a list of credentials, and importing 197
        # of 200 people would quietly leave three of them unable to vote. If
        # any line is wrong the command broadcasts `:invalid_rows` with every
        # problem and changes nothing.
        #
        # The details voters type to be found on the list are chosen in the
        # same step and stored with it, so a list is never left with people in
        # it that nobody can be identified by.
        #
        # Broadcasts:
        #   :ok, count              imported
        #   :invalid_rows, outcome  the file has lines to fix (RowMapper outcome)
        #   :no_rows, outcome       nothing is wrong, there is simply nobody
        #                           to import: an empty file, or one that
        #                           still holds only the template's example
        #                           line. Kept apart from `:invalid_rows`
        #                           because "0 lines need fixing" tells an
        #                           admin nothing about what to do next.
        #   :invalid                form invalid or election locked
        class ImportCensusFile < Decidim::Command
          BATCH_SIZE = 1_000

          def initialize(form, election, user)
            @form = form
            @election = election
            @user = user
          end

          def call
            return broadcast(:invalid) if form.invalid? || !election.editable?

            # Mapped once, by the form, which needed the rows to check that the
            # chosen identifiers tell every person apart.
            outcome = form.outcome
            return broadcast(:invalid_rows, outcome) if outcome.failed?
            return broadcast(:no_rows, outcome) if outcome.rows.empty?

            import!(outcome.rows)
            form.file.purge_later
            PreflightTrigger.call(election.reload)

            broadcast(:ok, outcome.rows.size)
          end

          private

          attr_reader :form, :election, :user

          def import!(rows)
            now = Time.current
            Decidim::Elections::Voter.transaction do
              election.voters.delete_all
              rows.each_slice(BATCH_SIZE) do |slice|
                # Every row was validated by RowMapper; `Voter`'s only
                # validation is a non-empty `data`, which RowMapper guarantees.
                Decidim::Elections::Voter.insert_all( # rubocop:disable Rails/SkipsModelValidations
                  slice.map { |data| { election_id: election.id, data:, created_at: now, updated_at: now } }
                )
              end

              Decidim.traceability.update!(
                election,
                user,
                { census_manifest: "token_csv", census_settings: settings(rows.size, now) },
                visibility: "admin-only"
              )
            end
          end

          def settings(count, now)
            {
              "columns" => form.settings_columns,
              "fields" => form.fields,
              "identifiers" => form.chosen_identifiers,
              "file" => {
                "name" => form.file.filename.to_s,
                "rows" => count,
                "imported_at" => now.iso8601
              }
            }
          end
        end
      end
    end
  end
end

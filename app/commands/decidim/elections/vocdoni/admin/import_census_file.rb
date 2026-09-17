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
        # Identifiers chosen earlier on the Security tab are kept when the new
        # file still has those columns, and dropped otherwise.
        #
        # Broadcasts:
        #   :ok, count              imported
        #   :invalid_rows, outcome  the file has problems (RowMapper outcome)
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

            outcome = CensusCsv::RowMapper.new(form.reader, form.mapping).call
            return broadcast(:invalid_rows, outcome) if outcome.failed? || outcome.rows.empty?

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
            previous = election.census_manifest.to_s == "token_csv" ? election.census_settings.to_h : {}
            identifiers = Array(previous["identifiers"]) & form.fields

            {
              "columns" => form.settings_columns,
              "fields" => form.fields,
              "identifiers" => identifiers,
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

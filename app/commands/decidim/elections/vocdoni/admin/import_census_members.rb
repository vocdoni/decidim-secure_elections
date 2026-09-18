# frozen_string_literal: true

require "csv"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Imports a census from an uploaded CSV.
      #
      # Deliberately **not** atomic across rows: a file with three bad rows out
      # of two hundred imports the other hundred and ninety-seven and reports
      # what was wrong with the three. Refusing the whole upload because one
      # birth date was typed `31/02/1990` leaves the admin editing a spreadsheet
      # blind, which is how censuses end up being pasted in by hand.
      #
      # Broadcasts `:ok` with a {Decidim::Elections::Vocdoni::CensusCsv::Result} when
      # anything was imported — the caller reports the failed rows — and
      # `:invalid` when nothing was.
      class ImportCensusMembers < Decidim::Command
        include Decidim::ProcessesFileLocally

        # @param form [Decidim::Elections::Vocdoni::Admin::CensusImportForm]
        # @param election [Decidim::Elections::Vocdoni::Election]
        # @param current_user [Decidim::User]
        def initialize(form, election, current_user)
          @form = form
          @election = election
          @current_user = current_user
        end

        def call
          return broadcast(:invalid) unless election.editable?
          return broadcast(:invalid) if form.invalid?

          result = import!

          return broadcast(:invalid, result) unless result.any_imported?

          broadcast(:ok, result)
        rescue CSV::MalformedCSVError, Vocdoni::CensusCsv::UnreadableFile
          broadcast(:invalid)
        end

        private

        attr_reader :form, :election, :current_user

        def import!
          result = nil

          process_file_locally(form.file) do |path|
            result = form.replace ? replace!(path) : read(path)
          end

          # `destroy_all` and a rolled-back transaction both leave the
          # association holding a view of the census that is no longer true.
          election.census_members.reset
          election.refresh_census_size!
          log_change(result)

          result
        end

        def read(path)
          Vocdoni::CensusCsv::Importer.new(election, path).import!
        end

        # "Replace the current census" — the one routine action here that
        # destroys data.
        #
        # Two things make it safe enough to offer. The count of what was
        # removed travels back on the result, so the flash can say what
        # actually happened rather than only what was added; and the whole
        # thing is one transaction that is thrown away when the file turns out
        # to be unusable. Without that second half, uploading a file whose
        # every row was rejected emptied the census and reported only
        # "nothing could be imported" — an admin left with no census, no
        # explanation and no undo.
        def replace!(path)
          result = nil

          Vocdoni::CensusMember.transaction do
            removed = election.census_members.destroy_all.size
            result = read(path)

            raise ActiveRecord::Rollback unless result.any_imported?

            result.removed = removed
          end

          result
        end

        def log_change(result)
          Decidim.traceability.perform_action!(:update_census, election, current_user, visibility: "admin-only") do
            election
          end

          result
        end
      end
    end
  end
end
end

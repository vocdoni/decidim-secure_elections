# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # Census tab: voter-authentication configuration + member management.
      #
      # The census belongs to Decidim. An admin never sees, types or is asked
      # for a Vocdoni identifier: they configure how a voter authenticates,
      # they fill in the people, and the publish job creates the members, the
      # group and the census upstream in that order (ARCHITECTURE §4c).
      #
      # Nothing here talks to the API (ARCHITECTURE §0.5). Everything on this page
      # is a local read or a local write.
      #
      # Actions
      # -------
      # * `show`     — unified hub: manifest selector, inline auth-config form,
      #                5-row preview, members management, import/verification.
      # * `edit`/`update` — voter authentication (credentials, 2FA, summary).
      #                Still reachable but no longer linked; `show` absorbs it.
      # * `members`/`update_members` — the editable table.
      # * `template` — a CSV with exactly the columns this election needs.
      # * `import`   — read a CSV back, per row.
      # * `import_from_verifications` — pull in verified participants.
      # * `clear`    — empty the census.
      class CensusController < Admin::ApplicationController
        # The census tab requires questions to be complete first; the guard
        # redirects and explains if they are not.
        wizard_step :census

        # Only the "internal_users" manifest ships with vd today.  Future
        # manifests (token_csv, dataset_csv, …) add a key here and a
        # corresponding `admin/censuses/_<key>_form.html.erb` partial.
        CENSUS_MANIFESTS = ["internal_users"].freeze

        helper_method :census_members, :incomplete_members, :reported_missing_members,
                      :available_handlers, :verifications_form, :import_form, :template_fields,
                      :preview_users

        def show
          enforce_permission_to(:read, :census, election:)

          @census_manifests = CENSUS_MANIFESTS
          @form = census_form
        end

        def edit
          enforce_permission_to(:read, :census, election:)

          @form = census_form
        end

        def update
          enforce_permission_to(:update, :census, election:)

          @form = form(Decidim::SecureElections::Admin::CensusForm).from_params(params, election:)

          Decidim::SecureElections::Admin::UpdateElectionCensus.call(@form, election) do
            on(:ok) do
              flash[:notice] = I18n.t("census.authentication.success", scope: "decidim.secure_elections.admin")
              redirect_to election_census_path(election)
            end

            on(:invalid) do
              flash.now[:alert] = I18n.t("census.authentication.invalid", scope: "decidim.secure_elections.admin")
              # The auth-config form is now inline on `show`, so re-render that.
              @census_manifests = CENSUS_MANIFESTS
              render action: "show", status: :unprocessable_content
            end
          end
        end

        # The editable table. Always renders one blank row so the page is
        # usable — and the census can be started — without JavaScript.
        def members
          enforce_permission_to(:read, :census, election:)

          @form = members_form
        end

        def update_members
          enforce_permission_to(:update, :census, election:)

          @form = form(Decidim::SecureElections::Admin::CensusMembersForm).from_params(params, election:)

          Decidim::SecureElections::Admin::UpdateCensusMembers.call(@form, election, current_user) do
            on(:ok) do
              flash[:notice] = I18n.t("census.members.update.success", scope: "decidim.secure_elections.admin")
              redirect_to election_census_path(election)
            end

            on(:invalid) do
              flash.now[:alert] = I18n.t("census.members.update.invalid", scope: "decidim.secure_elections.admin")
              render action: "members", status: :unprocessable_content
            end
          end
        end

        # A CSV with exactly the columns the admin ticked — the Vocdoni app's
        # "Download Import Template", which is what makes the import round-trip
        # rather than a guessing game about header names.
        def template
          enforce_permission_to(:read, :census, election:)

          csv_template = Decidim::SecureElections::CensusCsv::Template.new(template_fields)

          if csv_template.any?
            send_data csv_template.to_csv, filename: csv_template.filename, type: "text/csv; charset=utf-8"
          else
            flash[:alert] = I18n.t("census.template.no_columns", scope: "decidim.secure_elections.admin")
            redirect_to election_census_path(election)
          end
        end

        def import
          enforce_permission_to(:update, :census, election:)

          @import_form = form(Decidim::SecureElections::Admin::CensusImportForm).from_params(params, election:)
          # Built here rather than in the `:invalid` branch. `Decidim::Command`
          # runs those branches with `instance_eval`, so inside them `self` is
          # the command: an `@form =` assignment would set an ivar on the
          # command and never reach the view, and `form(…)` would resolve to
          # the command's own private `attr_reader :form` — a zero-argument
          # method — rather than to `Decidim::FormFactory#form`.
          @census_manifests = CENSUS_MANIFESTS
          @form = census_form

          Decidim::SecureElections::Admin::ImportCensusMembers.call(@import_form, election, current_user) do
            on(:ok) do |result|
              # Partial success is the normal case and is reported as such:
              # what came in, and what did not and why.
              flash[:notice] = import_success_message(result)
              flash[:alert] = failed_rows_message(result) if result.any_failures?
              redirect_to election_census_path(election)
            end

            on(:invalid) do |result|
              flash.now[:alert] = import_failure_message(result)
              render action: "show", status: :unprocessable_content
            end
          end
        end

        def import_from_verifications
          enforce_permission_to(:update, :census, election:)

          @verifications_form = form(Decidim::SecureElections::Admin::CensusVerificationsForm)
                                .from_params(params, election:, current_organization:)
          # Same reason as in `import`: the branches below run against the
          # command, not against this controller.
          @census_manifests = CENSUS_MANIFESTS
          @form = census_form

          Decidim::SecureElections::Admin::ImportCensusMembersFromVerifications.call(@verifications_form, election, current_user) do
            on(:ok) do |imported|
              flash[:notice] = I18n.t("census.verifications.success", scope: "decidim.secure_elections.admin", count: imported)
              redirect_to election_census_path(election)
            end

            on(:invalid) do
              flash.now[:alert] = verifications_failure_message
              render action: "show", status: :unprocessable_content
            end
          end
        end

        def clear
          enforce_permission_to(:update, :census, election:)

          Decidim::SecureElections::Admin::DestroyCensusMembers.call(election, current_user) do
            on(:ok) do |count|
              flash[:notice] = I18n.t("census.clear.success", scope: "decidim.secure_elections.admin", count:)
              redirect_to election_census_path(election)
            end

            on(:invalid) do
              flash[:alert] = I18n.t("census.clear.invalid", scope: "decidim.secure_elections.admin")
              redirect_to election_census_path(election)
            end
          end
        end

        private

        # The voter-authentication form the `show` template renders. Also what
        # the import actions fall back to when they have to re-render `show`.
        def census_form
          form(Decidim::SecureElections::Admin::CensusForm).from_model(election, election:)
        end

        # First five members for the preview partial. Memoised so the same
        # query is not run twice when the page renders (once for `present?`,
        # once for the rows).
        def preview_users(current_election)
          @preview_users ||= current_election.census_members.first(5)
        end

        def census_members
          @census_members ||= election.census_members
        end

        def incomplete_members
          @incomplete_members ||= election.incomplete_census_members
        end

        # Rows the upstream group validation named. Only ever populated after a
        # failed publish attempt, and only useful because members carry their
        # `vocdoni_member_id` (ARCHITECTURE §4c-bis).
        def reported_missing_members
          @reported_missing_members ||= election.census_members_reported_missing
        end

        # Always one row more than there are people, so the census can be
        # started — and added to — without JavaScript.
        def members_form
          form(Decidim::SecureElections::Admin::CensusMembersForm).from_model(election, election:).tap do |built|
            built.members << blank_member_form
          end
        end

        def blank_member_form
          form(Decidim::SecureElections::Admin::CensusMemberForm).from_params({}, election:)
        end

        def import_form
          @import_form ||= form(Decidim::SecureElections::Admin::CensusImportForm).from_params({}, election:)
        end

        def verifications_form
          @verifications_form ||= form(Decidim::SecureElections::Admin::CensusVerificationsForm)
                                  .from_params({}, election:, current_organization:)
        end

        def available_handlers
          @available_handlers ||= Decidim::SecureElections::VerifiedParticipants.available_handlers(current_organization)
        end

        # Which columns the template should carry. Defaults to what this
        # election actually needs, so the common path is one click.
        def template_fields
          @template_fields ||= begin
            requested = Array(params[:fields]).map(&:to_s) & Decidim::SecureElections::CensusMember::FIELDS
            requested.presence || election.census_columns
          end
        end

        # Why an import produced nothing. Three different things can go wrong
        # and each has to be said out loud, because the admin's only other
        # signal is an unchanged member list:
        #
        # * the file was read and every row was refused — name the rows;
        # * the file itself was refused (missing, not a CSV, no known column)
        #   — the form knows why, so say that;
        # * neither, i.e. the election is already on chain — a flat statement.
        # * every row there was, was the template's own example — which is the
        #   whole content of a template uploaded unedited, and reads as a
        #   broken importer unless the skip is named.
        def import_failure_message(result)
          reported = [failed_rows_message(result), skipped_examples_message(result)].compact_blank.join(" ")
          return reported if reported.present?

          form_errors_message(@import_form).presence ||
            I18n.t("census.import.invalid", scope: "decidim.secure_elections.admin")
        end

        # The template's example row, recognised and left out rather than
        # imported as a person
        # ({Decidim::SecureElections::CensusCsv::Importer#example_row?}).
        #
        # Said out loud in both the success notice and the failure alert. A row
        # the admin can see in their own file and cannot find in the census
        # afterwards is worse than the import that put Ada Lovelace in it.
        def skipped_examples_message(result)
          return nil if result.blank? || !result.any_skipped_examples?

          I18n.t("census.import.skipped_example", scope: "decidim.secure_elections.admin", count: result.skipped_examples_count)
        end

        # What the import did, in the order it did it.
        #
        # "2 people were added to the census" was the whole message even when
        # the import had just deleted seven others on the way in, which is the
        # one case where an admin most needs to be told. Two sentences rather
        # than one interpolated string: each number pluralizes on its own, and
        # I18n cannot pluralize on two counts at once.
        def import_success_message(result)
          added = I18n.t("census.import.success", scope: "decidim.secure_elections.admin", count: result.imported_count)
          removed = I18n.t("census.import.replaced", scope: "decidim.secure_elections.admin", count: result.removed_count) if result.any_removed?

          [removed, added, skipped_examples_message(result)].compact.join(" ")
        end

        def verifications_failure_message
          form_errors_message(@verifications_form).presence ||
            I18n.t("census.verifications.invalid", scope: "decidim.secure_elections.admin")
        end

        def form_errors_message(form_object)
          return nil if form_object.blank?

          form_object.errors.full_messages.to_sentence
        end

        # "Row 4: Email is invalid", up to a readable number of them.
        def failed_rows_message(result)
          return nil if result.blank? || !result.any_failures?

          shown = result.failed_rows.first(10).map do |row|
            I18n.t("census.import.failed_row", scope: "decidim.secure_elections.admin", number: row.number, reason: row.summary)
          end

          remaining = result.failed_count - shown.size
          shown << I18n.t("census.import.more_failures", scope: "decidim.secure_elections.admin", count: remaining) if remaining.positive?

          I18n.t("census.import.failures", scope: "decidim.secure_elections.admin", count: result.failed_count, rows: shown.join(" "))
        end
      end
    end
  end
end

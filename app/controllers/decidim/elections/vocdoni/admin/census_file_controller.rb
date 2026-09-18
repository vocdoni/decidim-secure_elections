# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # The forms inside the "Your list" card on the Census tab.
        #
        # This controller has no pages of its own. Every action answers a form
        # the admin submitted from the card and puts them back on the tab:
        #
        #   create              → the file, read; back to the tab with `?blob=`
        #                         so the card shows what we made of it
        #   update              → import it, or the tab again with the lines
        #                         to fix and the file still on it
        #   update_identifiers  → change the details voters type, later
        #   destroy             → remove the list
        #   template            → a starter file to download
        #
        # Redirect after a success, render after a refusal: a refused form has
        # state worth keeping on screen, a successful one must not be posted
        # twice by a reload.
        #
        # Every action needs the same permission as the Census tab itself, so
        # the card closes once the election can no longer be edited.
        class CensusFileController < ::Decidim::Elections::Admin::ApplicationController
          include Decidim::Elections::Vocdoni::CensusTabData

          helper_method :election, :census_path, :census_file_path, :template_path

          before_action { enforce_permission_to(:update, :census, election:) }

          def create
            @upload_form = form(AdminForms::CensusFileUploadForm).from_params(params)

            unless @upload_form.valid?
              flash[:alert] = @upload_form.errors[:file].to_sentence.presence ||
                              I18n.t("census_file.create.invalid", scope: "decidim.elections.vocdoni.admin")
              # A file input cannot be refilled from the server, so there is
              # nothing on the page worth preserving: the card goes back to its
              # drop zone with the reason above it.
              return redirect_to census_path
            end

            ActiveStorage::PurgeJob.set(wait: UPLOAD_LIFETIME).perform_later(@upload_form.blob)
            redirect_to census_path(manifest: "token_csv", blob: @upload_form.blob.signed_id(expires_in: UPLOAD_LIFETIME))
          end

          def update
            @mapping_form = form(AdminForms::CensusFileMappingForm).from_params(params)
            return redirect_to_drop_zone if @mapping_form.file.blank?

            # Captured before the command: its `on` blocks run with the command
            # as `self`, where the controller's helpers do not exist.
            done_path = census_path
            refused = method(:render_refused_import)

            ImportCensusFile.call(@mapping_form, election, current_user) do
              on(:ok) do |count|
                flash[:notice] = I18n.t("census_file.update.success", scope: "decidim.elections.vocdoni.admin", count:)
                redirect_to done_path
              end

              on(:invalid_rows) { |outcome| refused.call(outcome) }
              on(:no_rows) { |outcome| refused.call(outcome, empty: true) }
              on(:invalid) { refused.call(nil) }
            end
          end

          def update_identifiers
            @identifiers_form = form(AdminForms::CensusIdentifiersForm).from_params(params, election:)
            done_path = census_path
            refused = method(:render_census_tab)

            UpdateCensusIdentifiers.call(@identifiers_form, election, current_user) do
              on(:ok) do
                flash[:notice] = I18n.t("census_file.update_identifiers.success", scope: "decidim.elections.vocdoni.admin")
                redirect_to done_path
              end

              on(:invalid) { refused.call }
            end
          end

          def destroy
            done_path = census_path

            RemoveCensusFile.call(election, current_user) do
              on(:ok) do
                flash[:notice] = I18n.t("census_file.destroy.success", scope: "decidim.elections.vocdoni.admin")
                redirect_to done_path
              end

              on(:invalid) do
                flash[:alert] = I18n.t("census_file.destroy.invalid", scope: "decidim.elections.vocdoni.admin")
                redirect_to done_path
              end
            end
          end

          def template
            fields = Array(params[:fields]).map(&:to_s) & CensusCsv::Fields::TARGETS
            fields = %w(memberNumber name surname nationalId email) if fields.empty?

            send_data template_csv(fields),
                      filename: "participants-template.csv",
                      type: "text/csv; charset=utf-8"
          end

          private

          def election
            @election ||= ::Decidim::Elections::Election.where(component: current_component).find(params.expect(:election_id))
          end

          def admin_proxy
            @admin_proxy ||= Decidim::EngineRouter.admin_proxy(current_component)
          end

          # Upstream's named routes are not helpers here (this controller lives
          # outside `Decidim::Elections::Admin`), so they are reached through
          # the component's admin proxy.
          def census_path(**query)
            admin_proxy.census_election_path(election, **query)
          end

          def census_file_path(**query)
            admin_proxy.election_census_file_path(election, **query)
          end

          def template_path(**query)
            admin_proxy.template_election_census_file_path(election, **query)
          end

          # The Census tab, rendered from here rather than redirected to,
          # because what was refused is on the page and would be lost.
          #
          # The type is set in memory only: a file census that has never been
          # imported has not saved one yet, and without it the card the admin
          # is looking at would be the hidden one.
          def render_census_tab(status: :unprocessable_content)
            election.census_manifest = "token_csv"
            render "decidim/elections/admin/census/edit", status:
          end

          # An import that changed nothing, with the file still on screen: the
          # lines to fix, or the news that there was nobody in it.
          def render_refused_import(outcome, empty: false)
            @import_outcome = outcome

            if empty
              key = outcome.skipped_examples.to_i.positive? ? "only_example" : "no_people"
              flash.now[:alert] = I18n.t("census_file.update.#{key}", scope: "decidim.elections.vocdoni.admin")
            elsif outcome.blank?
              flash.now[:alert] = I18n.t("census_file.update.invalid", scope: "decidim.elections.vocdoni.admin")
            end

            render_census_tab
          end

          # The signed link to the file expired, or the file was cleared up
          # while the admin was reading the page: there is nothing to import
          # any more, so the card asks for it again.
          def redirect_to_drop_zone
            flash[:alert] = I18n.t("census_file.file_missing", scope: "decidim.elections.vocdoni.admin")
            redirect_to census_path(manifest: "token_csv")
          end

          # A header row plus one example line, with the separator Spanish
          # and Catalan spreadsheets open by default.
          def template_csv(fields)
            csv = CSV.generate(col_sep: ";") do |rows|
              rows << fields.map { |field| CensusCsv::Fields.label(field) }
              rows << fields.map { |field| CensusCsv::Fields.example(field) }
            end
            # The byte-order mark makes Excel on Windows read the file as UTF-8.
            "﻿#{csv}"
          end
        end
      end
    end
  end
end

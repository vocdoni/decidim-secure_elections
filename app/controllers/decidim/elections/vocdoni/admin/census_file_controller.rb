# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # "Participants from a file", reached from the Census tab. One page
        # with two states rather than a wizard:
        #
        #   new                  → upload a CSV (`create` reads it and comes
        #                          back here with `?blob=`, so a refresh
        #                          cannot re-post the file)
        #   new?blob=…           → what we understood of it, what we could
        #                          not place, and which details voters type
        #   update               → import, or the same page again with the
        #                          lines to fix
        #
        # plus `identifiers`/`update_identifiers` (change those details later,
        # without uploading the file again), `destroy` (remove the list) and
        # `template` (a starter file).
        #
        # Every action needs the same permission as the Census tab itself, so
        # the page closes once the election can no longer be edited.
        class CensusFileController < ::Decidim::Elections::Admin::ApplicationController
          helper_method :election, :census_path, :wizard_path, :template_path

          UPLOAD_LIFETIME = 2.hours

          before_action { enforce_permission_to(:update, :census, election:) }

          def new
            @upload_form = form(AdminForms::CensusFileUploadForm).instance
            @form = mapping_form if params[:blob].present?
            return redirect_to_upload if params[:blob].present? && @form.reader.blank?

            render :new
          end

          def create
            @upload_form = form(AdminForms::CensusFileUploadForm).from_params(params)

            if @upload_form.valid?
              # The file holds personal data and is only needed until the
              # import: its link expires and the file is removed after a while
              # even if the page is abandoned (a finished import removes it
              # straight away).
              ActiveStorage::PurgeJob.set(wait: UPLOAD_LIFETIME).perform_later(@upload_form.file)
              # Back to the same page, now with the file read: one screen, and
              # a refresh cannot re-post the upload.
              redirect_to wizard_path(:new, blob: @upload_form.file.signed_id(expires_in: UPLOAD_LIFETIME))
            else
              flash.now[:alert] = I18n.t("census_file.create.invalid", scope: "decidim.elections.vocdoni.admin")
              render :new, status: :unprocessable_content
            end
          end

          # Changing the chosen details on a list that is already imported.
          def identifiers
            @form = AdminForms::CensusIdentifiersForm.from_model(election)
            return redirect_to census_path if @form.identifier_options.empty?

            render :identifiers
          end

          def update_identifiers
            @form = form(AdminForms::CensusIdentifiersForm).from_params(params, election:)
            done_path = census_path

            UpdateCensusIdentifiers.call(@form, election, current_user) do
              on(:ok) do
                flash[:notice] = I18n.t("census_file.update_identifiers.success", scope: "decidim.elections.vocdoni.admin")
                redirect_to done_path
              end

              on(:invalid) do
                flash.now[:alert] = I18n.t("census_file.update_identifiers.invalid", scope: "decidim.elections.vocdoni.admin")
                render :identifiers, status: :unprocessable_content
              end
            end
          end

          def update
            @upload_form = form(AdminForms::CensusFileUploadForm).instance
            @form = form(AdminForms::CensusFileMappingForm).from_params(params)
            return redirect_to_upload if @form.file.blank?

            # Captured before the command: its `on` blocks run with the
            # command as `self`, where the controller's helpers do not exist.
            #
            # Back to the Census tab: the admin came from there, and the list
            # and the details voters type are the whole of what this page
            # decides. Security is a tab click away, like any other.
            done_path = census_path
            errors_view = method(:render_row_errors)
            empty_view = method(:render_no_rows)

            ImportCensusFile.call(@form, election, current_user) do
              on(:ok) do |count|
                flash[:notice] = I18n.t("census_file.update.success", scope: "decidim.elections.vocdoni.admin", count:)
                redirect_to done_path
              end

              on(:invalid_rows) do |outcome|
                errors_view.call(outcome)
              end

              on(:no_rows) do |outcome|
                empty_view.call(outcome)
              end

              on(:invalid) do
                flash.now[:alert] = I18n.t("census_file.update.invalid", scope: "decidim.elections.vocdoni.admin")
                render :new, status: :unprocessable_content
              end
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

          # Upstream's named routes are not helpers here — this controller
          # lives outside `Decidim::Elections::Admin` — so they are reached
          # through the component's admin proxy.
          def census_path
            admin_proxy.census_election_path(election)
          end

          def wizard_path(action = :new, **query)
            case action
            when :new then admin_proxy.new_election_census_file_path(election, **query)
            when :identifiers then admin_proxy.identifiers_election_census_file_path(election, **query)
            else admin_proxy.election_census_file_path(election, **query)
            end
          end

          def template_path(**query)
            admin_proxy.template_election_census_file_path(election, **query)
          end

          # The page's second state: a file read, its columns matched (from what
          # the admin sent, or from what the headings suggest) and the details
          # voters will type.
          def mapping_form
            form = form(AdminForms::CensusFileMappingForm).from_params(blob: params[:blob])
            return form if form.reader.blank?

            submitted = params[:census_file].presence
            form.columns = submitted ? (submitted[:columns]&.to_unsafe_h || {}) : AdminForms::CensusFileMappingForm.suggested_columns(form.reader)
            form.identifiers = Array(submitted[:identifiers]).map(&:to_s) if submitted
            form
          end

          def redirect_to_upload
            flash[:alert] = I18n.t("census_file.new.file_missing", scope: "decidim.elections.vocdoni.admin")
            redirect_to wizard_path(:new)
          end

          # Everything about this file is answered on its own page, including
          # what is wrong with it: a separate errors screen made the admin
          # navigate back to a form they had already filled in.
          def render_row_errors(outcome)
            @outcome = outcome
            render :new, status: :unprocessable_content
          end

          # Nothing was wrong with the file — there was simply nobody in it to
          # import. The "lines to fix" page would have an empty table, so the
          # admin goes back to the matching step, which keeps their file and
          # their choices and says what the file is missing.
          def render_no_rows(outcome)
            key = outcome.skipped_examples.to_i.positive? ? "only_example" : "no_people"
            flash.now[:alert] = I18n.t("census_file.update.#{key}", scope: "decidim.elections.vocdoni.admin")
            @outcome = outcome
            render :new, status: :unprocessable_content
          end

          # A header row plus one example line, with the separator Spanish
          # and Catalan spreadsheets open by default.
          def template_csv(fields)
            csv = CSV.generate(col_sep: ";") do |rows|
              rows << fields.map { |field| CensusCsv::Fields.label(field) }
              rows << fields.map { |field| CensusCsv::Fields.example(field) }
            end
            # The byte-order mark makes Excel on Windows read the file as UTF-8.
            "\uFEFF#{csv}"
          end
        end
      end
    end
  end
end

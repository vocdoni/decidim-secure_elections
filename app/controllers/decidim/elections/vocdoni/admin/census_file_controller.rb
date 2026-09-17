# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # The "Participants from a file" wizard, reached from the Census tab:
        #
        #   new    → upload a CSV          (create)
        #   edit   → say what each column means (update → import)
        #   errors → the lines to fix, when the import is refused
        #
        # plus `destroy` (remove the list) and `template` (a starter file).
        #
        # Every action needs the same permission as the Census tab itself, so
        # the wizard closes once the election can no longer be edited.
        class CensusFileController < ::Decidim::Elections::Admin::ApplicationController
          helper_method :election, :census_path, :wizard_path, :template_path

          UPLOAD_LIFETIME = 2.hours

          before_action { enforce_permission_to(:update, :census, election:) }

          def new
            @form = form(AdminForms::CensusFileUploadForm).instance
          end

          def create
            @form = form(AdminForms::CensusFileUploadForm).from_params(params)

            if @form.valid?
              # The file holds personal data and is only needed while the admin
              # matches its columns: its link expires and the file is removed
              # after a while even if the wizard is abandoned (a successful
              # import removes it straight away).
              ActiveStorage::PurgeJob.set(wait: UPLOAD_LIFETIME).perform_later(@form.file)
              redirect_to wizard_path(:edit, blob: @form.file.signed_id(expires_in: UPLOAD_LIFETIME))
            else
              flash.now[:alert] = I18n.t("census_file.create.invalid", scope: "decidim.elections.vocdoni.admin")
              render :new, status: :unprocessable_content
            end
          end

          def edit
            @form = form(AdminForms::CensusFileMappingForm).from_params(blob: params[:blob])
            return redirect_to_upload if @form.reader.blank?

            @form.columns = AdminForms::CensusFileMappingForm.suggested_columns(@form.reader) if params[:census_file].blank?
            @form.columns = params.dig(:census_file, :columns)&.to_unsafe_h || {} if params[:census_file].present?
          end

          def update
            @form = form(AdminForms::CensusFileMappingForm).from_params(params)
            return redirect_to_upload if @form.file.blank?

            # Captured before the command: its `on` blocks run with the
            # command as `self`, where the controller's helpers do not exist.
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
                render :edit, status: :unprocessable_content
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
            when :edit then admin_proxy.edit_election_census_file_path(election, **query)
            else admin_proxy.election_census_file_path(election, **query)
            end
          end

          def template_path(**query)
            admin_proxy.template_election_census_file_path(election, **query)
          end

          def redirect_to_upload
            flash[:alert] = I18n.t("census_file.edit.file_missing", scope: "decidim.elections.vocdoni.admin")
            redirect_to wizard_path(:new)
          end

          def render_row_errors(outcome)
            @outcome = outcome
            render :errors, status: :unprocessable_content
          end

          # Nothing was wrong with the file — there was simply nobody in it to
          # import. The "lines to fix" page would have an empty table, so the
          # admin goes back to the matching step, which keeps their file and
          # their choices and says what the file is missing.
          def render_no_rows(outcome)
            key = outcome.skipped_examples.to_i.positive? ? "only_example" : "no_people"
            flash.now[:alert] = I18n.t("census_file.update.#{key}", scope: "decidim.elections.vocdoni.admin")
            render :edit, status: :unprocessable_content
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

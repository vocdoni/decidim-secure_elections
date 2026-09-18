# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Everything the Census tab needs to render, for whichever controller is
      # rendering it.
      #
      # Two of them do. Upstream's `CensusController` shows the tab and saves
      # it; {Admin::CensusFileController} answers the forms inside the "Your
      # list" card and, when one of them is refused, renders the very same page
      # back with the file still on it. That is the whole reason this is split
      # out of {CensusPage}: the data is shared, the save guard is not.
      #
      # The page itself is `app/views/decidim/elections/admin/census/edit.html.erb`
      # in this engine, which takes precedence over upstream's file of the same
      # name. Engine view paths are prepended in load order, and this module is
      # not a declared dependency of upstream's, so the path is prepended here
      # explicitly rather than trusted to come out on top by itself.
      #
      # Everything below is presentation data, exposed lazily as helpers so it
      # is computed at render time: `update` builds its own `@form` inside the
      # action, after any `before_action` would have run.
      module CensusTabData
        extend ActiveSupport::Concern

        # How long an uploaded file stays readable while the admin looks at
        # what we made of it. It holds personal data and is only needed until
        # the import, so its link expires and the file is removed even if the
        # page is abandoned; a finished import removes it straight away.
        UPLOAD_LIFETIME = 2.hours

        included do
          prepend_view_path Decidim::Elections::Vocdoni::Engine.root.join("app", "views")

          helper Decidim::Elections::Vocdoni::Admin::CensusSetupHelper
          # `preview_users`, which the card's sample table asks for.
          helper Decidim::Elections::Admin::ElectionsHelper
          helper_method :internal_users_form, :verification_rows, :eligible_count,
                        :census_voters_count, :mapping_form, :identifiers_form, :import_outcome
        end

        private

        # The file the admin has just uploaded, read and matched to what we
        # understand of it. Absent unless there is one: the card is then in its
        # empty or its list state.
        #
        # An action that built one of its own keeps it, which is what puts a
        # refused import back on screen with its file: the parenthesis matters,
        # or a trailing `if` would throw that form away.
        def mapping_form
          @mapping_form ||= (build_mapping_form(params[:blob]) if params[:blob].present?)
        end

        # Rebuilt from the signed id rather than kept anywhere: the page can be
        # reloaded, and the file survives exactly as long as the signature.
        def build_mapping_form(signed_id)
          form = form(AdminForms::CensusFileMappingForm).from_params(blob: signed_id)
          return form if form.reader.blank?

          submitted = params[:census_file].presence
          form.columns = submitted ? (submitted[:columns]&.to_unsafe_h || {}) : mapping_form_class.suggested_columns(form.reader)
          form.identifiers = Array(submitted[:identifiers]).map(&:to_s) if submitted
          form
        end

        def mapping_form_class
          AdminForms::CensusFileMappingForm
        end

        # The details voters type, for a list that is already imported.
        def identifiers_form
          @identifiers_form ||= AdminForms::CensusIdentifiersForm.from_model(election)
        end

        # Set by an import that was refused over its rows, so the card can say
        # which lines to fix without reading the file again.
        attr_reader :import_outcome

        # The "Registered participants" set-up block is always rendered, so it
        # always needs a form object: the one the action built when that is the
        # census being saved, otherwise one rebuilt from what is stored.
        def internal_users_form
          @internal_users_form ||=
            if @form.is_a?(::Decidim::Elections::Admin::Censuses::InternalUsersForm)
              @form
            else
              form(::Decidim::Elections::Admin::Censuses::InternalUsersForm)
                .from_params(stored_internal_users_settings, election:)
            end
        end

        # Only the keys that form knows; a file census keeps its own settings
        # under different names.
        def stored_internal_users_settings
          return {} unless election.census_manifest.to_s == "internal_users"

          election.census_settings.to_h.slice("authorization_handlers")
        end

        # One row per verification the organisation offers, in the order
        # Decidim registers them. `granted` is a count query each: there are a
        # handful of workflows, and the number is the whole point of the row.
        def verification_rows
          @verification_rows ||= internal_users_form.available_authorizations.map do |workflow|
            {
              workflow:,
              name: workflow.name.to_s,
              granted: authorized_users_count([workflow.name.to_s])
            }
          end
        end

        # How many people could vote with the verifications currently ticked:
        # the same query the `internal_users` census runs.
        def eligible_count
          @eligible_count ||= authorized_users_count(internal_users_form.authorization_handlers_names.compact_blank)
        end

        def census_voters_count
          @census_voters_count ||= ::Decidim::Elections::Voter.where(election:).count
        end

        def authorized_users_count(handlers)
          ::Decidim::AuthorizedUsers.new(organization: current_organization, handlers:, strict: true).query.count
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Creates a draft election from step 1 of the wizard.
      #
      # A title is all it takes. The ballot, the census and the schedule are
      # steps of their own and are saved by their own commands — asking for all
      # of them before the record exists is what made the previous wizard
      # unusable.
      #
      # Nothing is written to the blockchain here — that only happens in
      # `SetupElection`, behind an explicit typed confirmation.
      class CreateElection < Decidim::Commands::CreateResource
        include Decidim::Elections::Vocdoni::Admin::ElectionAttributes

        protected

        def resource_class = Decidim::Elections::Vocdoni::Election

        def extra_params = { visibility: "all" }

        def attributes
          @attributes ||= election_attributes.merge(
            component: form.current_component,
            status: "draft"
          )
        end
      end
    end
  end
end
end

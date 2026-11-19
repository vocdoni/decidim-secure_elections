# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto upstream's `Decidim::Elections::VotesController` (see
      # the `extend_upstream` initializer in `engine.rb`).
      #
      # A Vocdoni election is voted only through Decidim's booth running the
      # `vocdoni` voting backend: no Decidim vote record is ever cast for it.
      # Where that backend is not active (a Decidim without client-side voting
      # backends), every action but the receipt renders a notice instead, so
      # upstream's server-side wizard never takes a ballot for the election.
      module RedirectsVoterToBooth
        extend ActiveSupport::Concern

        included do
          before_action :render_vocdoni_booth_if_backed
        end

        private

        def render_vocdoni_booth_if_backed
          return if election.vocdoni_process.blank?
          return if action_name == "receipt"
          return if Decidim::Elections::Vocdoni::VotingBackend.active_for?(election)

          render template: "decidim/elections/vocdoni/booth/show",
                 layout: "decidim/election_booth",
                 locals: { election: }
        end
      end
    end
  end
end

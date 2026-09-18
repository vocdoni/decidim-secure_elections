# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Saves step 1 of the wizard: the title, the description and the video.
      #
      # Refuses outright once the process exists on chain. The payload written
      # to Vocdoni is immutable, and letting Decidim drift away from it would
      # show voters a different question from the one they are signing.
      class UpdateElection < Decidim::Commands::UpdateResource
        include Decidim::Elections::Vocdoni::Admin::ElectionAttributes

        private

        alias election resource

        def invalid?
          return true unless election.editable?

          form.invalid?
        end

        def attributes
          @attributes ||= election_attributes
        end
      end
    end
  end
end
end

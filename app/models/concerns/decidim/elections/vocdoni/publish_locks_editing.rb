# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto {Decidim::Elections::Election} by `phase_4_spike`.
      #
      # Overrides `editable?` for Vocdoni-backed elections: publish is the
      # point-of-no-return, not Start. Once the election is published the
      # process, its questions and its census are anchored on the chain and
      # cannot be edited from Decidim without diverging from what voters see.
      #
      # For non-Vocdoni elections the upstream rule stands
      # (`published? ? !started? : !votes.exists?`), so this is a delta rather
      # than a replacement.
      module PublishLocksEditing
        def editable?
          return false if vocdoni_backed? && published?

          super
        end

        private

        # A Vocdoni-backed election is one that has opted in via the Security
        # tab — materialised as the presence of the sidecar row.
        def vocdoni_backed?
          vocdoni_process.present?
        end
      end
    end
  end
end

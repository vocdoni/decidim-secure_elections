# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Prepended onto {Decidim::Elections::Election} by `phase_4_spike`.
      #
      # In the v3 spike the Vocdoni push is deferred from Publish to Start —
      # the on-chain freeze happens when the admin clicks Start, not when
      # they Publish. Between Publish and Start the questions, census and
      # start_at can still change, and the Start-time push captures whatever
      # the admin decided. Once the election has actually started, the
      # process is on chain and further Decidim edits would diverge from
      # what voters see, so we lock at that point instead of at Publish.
      #
      # For non-Vocdoni elections the upstream rule stands
      # (`published? ? !started? : !votes.exists?`), so this is a delta rather
      # than a replacement.
      module PublishLocksEditing
        def editable?
          return false if vocdoni_backed? && started?

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

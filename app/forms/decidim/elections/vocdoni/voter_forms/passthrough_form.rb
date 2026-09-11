# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module VoterForms
        # Stub form registered as the census manifest's `voter_form` so
        # upstream's votes/new controller has something to render. The Vocdoni
        # booth is a client-side SPA at `/vocdoni/vote.html` that handles voter
        # authentication and ballot signing itself, so no server-side fields
        # are needed here — the form is a passthrough placeholder.
        class PassthroughForm < Decidim::Form
          mimic :vocdoni_voter

          def valid?
            true
          end

          # `Decidim::Elections::CensusManifest#voter_uid` calls `voter_uid` on
          # the form when set. Returning the current user's GID lets upstream's
          # session-scoping code (`session[:voter_uid]`) latch on to something
          # stable per Decidim user; the SPA authenticates against the SaaS
          # separately anyway.
          def voter_uid
            attributes[:current_user]&.to_global_id.to_s.presence
          end
        end
      end
    end
  end
end

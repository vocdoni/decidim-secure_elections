# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # The booth of an attested election fetches its voter's attestation here and forwards it to
      # the SaaS CSP's auth/0. Each call signs a fresh one with a fresh salt; the voter is the one
      # Decidim's census access let into the booth.
      class AttestationsController < Decidim::Elections::ApplicationController
        include Decidim::Elections::UsesCensusAccess

        def create
          enforce_permission_to(:create, :vote, election:)
          return head(:unauthorized) unless session_authenticated? && voter_uid.present?

          process = election.vocdoni_process
          return head(:not_found) unless process&.attested? && process.published? && process.vocdoni_process_id.present?

          render json: VoterAttestation.new(process, voter_uid).call
        rescue VoterAttestation::NoContact
          head :unprocessable_content
        rescue Decidim::Elections::Vocdoni::ApiError
          head :bad_gateway
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Persists the Security-tab choices onto the {Process} sidecar.
        #
        # The sidecar's presence is the opt-in signal read by the engine's
        # publish subscriber — if it exists, publish enqueues
        # {PublishElectionJob}. Its `metadata["settings"]` hash carries:
        #
        #   * `twofa_fields` — {SecurityForm#two_fa_fields}, forwarded
        #     verbatim as `twoFaFields`.
        #   * `auth_fields`  — {SecurityForm#selected_auth_fields}, forwarded
        #     verbatim as `authFields` (the CSP identity check).
        #
        # Semantics of the `enable_vocdoni` toggle:
        #   * OFF, no sidecar    → nothing to do.
        #   * OFF, sidecar exists, election still editable → delete sidecar
        #     (opt out; the election reverts to a plain Decidim election).
        #   * OFF, sidecar exists, election locked (published) → refuse:
        #     the on-chain process cannot be un-published from here.
        #   * ON, no sidecar     → create it in `pending`.
        #   * ON, sidecar exists → update `metadata["settings"]`.
        class UpdateElectionSecurity < Decidim::Command
          # @param form     [AdminForms::SecurityForm]
          # @param election [Decidim::Elections::Election]
          def initialize(form, election)
            @form = form
            @election = election
          end

          def call
            return broadcast(:invalid) if form.invalid?
            return broadcast(:invalid) unless election.editable?

            if form.enable_vocdoni
              enable!
            else
              disable!
            end

            broadcast(:ok)
          end

          private

          attr_reader :form, :election

          def enable!
            sidecar = election.vocdoni_process || Process.new(decidim_election_id: election.id, state: "pending")
            sidecar.metadata = sidecar.metadata.to_h.merge(
              "settings" => {
                "twofa_fields" => form.two_fa_fields,
                "auth_fields" => form.selected_auth_fields
              }
            )
            sidecar.save!
          end

          def disable!
            sidecar = election.vocdoni_process
            return if sidecar.blank?
            return if sidecar.published?

            sidecar.destroy!
          end
        end
      end
    end
  end
end

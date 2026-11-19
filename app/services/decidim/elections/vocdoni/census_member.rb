# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # The contact details of one census entry: a participant of an `internal_users` census
      # (`Decidim::User`) or a row of a `token_csv` one (`Decidim::Elections::Voter`). Only the
      # contact the one-time code goes to leaves Decidim; a CSV row's access `token` never does.
      module CensusMember
        # Keys a phone number may live under: in a CSV row's data or in the
        # metadata of a user's granted authorization. Decidim users carry no
        # phone of their own, and the bundled SMS handler only keeps a digest.
        PHONE_KEYS = %w(phone phone_number mobile_phone_number).freeze

        module_function

        # The census entry behind the `voter_uid` Decidim's census manifests mint (a GlobalID of
        # the user or of the CSV row), or nil when it does not belong to this election's census.
        def subject_for(election, voter_uid)
          return nil if voter_uid.blank?

          subject = GlobalID::Locator.locate(voter_uid, only: [Decidim::User, Decidim::Elections::Voter])
          case subject
          when Decidim::User
            subject if subject.decidim_organization_id == election.organization.id
          when Decidim::Elections::Voter
            subject if subject.election_id == election.id
          end
        rescue ActiveRecord::RecordNotFound, URI::Error, NameError
          nil
        end

        def email(subject)
          value = case subject
                  when Decidim::User then subject.email
                  when Decidim::Elections::Voter then subject.data.to_h["email"]
                  end
          value.to_s.strip.presence
        end

        # The first phone across the user's granted authorizations, oldest
        # first, so the attestation and the booth pick the same one.
        def phone(subject)
          sources = case subject
                    when Decidim::User
                      Decidim::Authorization.where(user: subject).where.not(granted_at: nil).order(:id).map { |auth| auth.metadata.to_h }
                    when Decidim::Elections::Voter
                      [subject.data.to_h]
                    else
                      []
                    end
          sources.each do |data|
            PHONE_KEYS.each do |key|
              value = data[key].to_s.strip
              return value if value.present?
            end
          end
          nil
        end
      end
    end
  end
end

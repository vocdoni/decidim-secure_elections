# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # What the Vocdoni memberbase and the booth learn about one census
      # entry: a participant of an `internal_users` census (`Decidim::User`)
      # or a row of a `token_csv` one (`Decidim::Elections::Voter`).
      #
      # Only the credential and the contact details the one-time code needs
      # leave Decidim. A CSV row's access `token` never does: it is what the
      # voter types to get into Decidim's census, not a Vocdoni field.
      module CensusMember
        # Keys a phone number may live under: in a CSV row's data or in the
        # metadata of a user's granted authorization. Decidim users carry no
        # phone of their own, and the bundled SMS handler only keeps a digest.
        PHONE_KEYS = %w(phone phone_number mobile_phone_number).freeze

        module_function

        # @param election [Decidim::Elections::Election]
        # @param subject [Decidim::User, Decidim::Elections::Voter]
        # @param two_fa_fields [Array<String>] the census `twoFaFields`; the
        #   phone is only sent when `"phone"` is among them, since it is
        #   personal data the SaaS has no other use for.
        # @return [Hash] a member for `POST /organizations/{addr}/members`.
        def payload(election, subject, two_fa_fields: [])
          member = {
            "memberNumber" => VoterCredential.for(election, subject),
            "name" => name(subject),
            "email" => email(subject)
          }
          member["phone"] = phone(subject) if two_fa_fields.include?("phone")
          member.compact_blank
        end

        def email(subject)
          value = case subject
                  when Decidim::User then subject.email
                  when Decidim::Elections::Voter then subject.data.to_h["email"]
                  end
          value.to_s.strip.presence
        end

        def name(subject)
          value = case subject
                  when Decidim::User then subject.name
                  when Decidim::Elections::Voter then subject.data.to_h["name"]
                  end
          value.to_s.strip.presence
        end

        def phone(subject)
          sources = case subject
                    when Decidim::User
                      Decidim::Authorization.where(user: subject).where.not(granted_at: nil).map { |auth| auth.metadata.to_h }
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

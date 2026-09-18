# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    module Admin
      # Building the census out of Decidim's own verifications.
      #
      # The admin picks one authorization handler and every participant who
      # holds it, granted, becomes a census member.
      class CensusVerificationsForm < Decidim::Form
        mimic :census_verifications

        attribute :authorization_handler, String

        # Replace the current census instead of adding to it.
        attribute :replace, Boolean, default: false

        validates :authorization_handler, presence: true
        validate :handler_is_available
        validate :handler_has_participants

        def election
          @election ||= context[:election]
        end

        def organization
          @organization ||= context[:current_organization]
        end

        def available_handlers
          @available_handlers ||= Vocdoni::VerifiedParticipants.available_handlers(organization)
        end

        def participants
          @participants ||= Vocdoni::VerifiedParticipants.new(organization, authorization_handler.to_s)
        end

        private

        def handler_is_available
          return if authorization_handler.blank?
          return if available_handlers.include?(authorization_handler)

          errors.add(:authorization_handler, :inclusion)
        end

        # Importing nothing is not a success. Saying so here saves the admin
        # from wondering whether the census silently failed.
        #
        # `FormBuilder#error_for` renders the message on its own, with no
        # attribute name in front of it, so an ActiveModel-style fragment
        # ("has not been granted to anybody yet…") reaches the page as half a
        # sentence next to the field. This message is a whole one, which is why
        # the error type is named for the condition rather than borrowed from
        # the shape of a Rails sentence fragment.
        def handler_has_participants
          return if authorization_handler.blank?
          return unless errors[:authorization_handler].empty?
          return if participants.count.positive?

          errors.add(:authorization_handler, :granted_to_nobody)
        end
      end
    end
  end
end
end

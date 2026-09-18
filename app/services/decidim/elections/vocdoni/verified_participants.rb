# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Participants of an organization who hold a granted authorization.
    #
    # This is the one census source the Vocdoni app cannot have, and the reason
    # this module exists: an organization that has already verified its
    # participants — by census CSV, by ID document, by post — should not have to
    # export and re-upload them to run a vote.
    #
    # Only granted authorizations count. A pending or rejected verification is
    # not an entitlement to vote, and neither is an account that has been
    # blocked or deleted since. Managed participants are excluded as well: they
    # have no real address, so nothing could ever be sent to them for 2FA.
    class VerifiedParticipants
      # @param organization [Decidim::Organization]
      # @param handler_name [String] an authorization workflow name, e.g.
      #   `"csv_census"`.
      def initialize(organization, handler_name)
        @organization = organization
        @handler_name = handler_name.to_s
      end

      attr_reader :organization, :handler_name

      # Authorization handlers this organization has switched on. Anything else
      # would authorize nobody, so the picker never offers it.
      #
      # @param organization [Decidim::Organization]
      # @return [Array<String>]
      def self.available_handlers(organization)
        Array(organization.available_authorizations).compact_blank
      end

      def self.handler_label(name)
        I18n.t("decidim.authorization_handlers.#{name}.name", default: name.to_s.humanize)
      end

      def valid_handler?
        self.class.available_handlers(organization).include?(handler_name)
      end

      # @return [ActiveRecord::Relation<Decidim::User>]
      def users
        return Decidim::User.none unless valid_handler?

        Decidim::User
          .where(organization:)
          .available
          .confirmed
          .where(id: granted_authorizations.select(:decidim_user_id))
      end

      def count
        users.count
      end

      # The census rows these participants would become.
      #
      # Decidim knows a participant's name and email and nothing else, so those
      # are the only fields that can be filled in. If the election also
      # authenticates on, say, a member number, the members table will show
      # those rows as incomplete — which is the honest answer, and visible
      # before publication rather than after.
      #
      # @return [Array<Hash>] attributes for {Decidim::Elections::Vocdoni::CensusMember}.
      def to_member_attributes
        users.map do |user|
          { name: user.name.presence, email: user.email.presence }
        end
      end

      private

      def granted_authorizations
        Decidim::Authorization.where(name: handler_name).where.not(granted_at: nil)
      end
    end
  end
end
end

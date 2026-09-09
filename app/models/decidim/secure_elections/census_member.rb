# frozen_string_literal: true

module Decidim
  module SecureElections
    # One person entitled to vote in a Vocdoni election.
    #
    # The census is Decidim's, not Vocdoni's. Members are collected here — by
    # hand, from a CSV, or from a Decidim verification — and only pushed
    # upstream by the publish job, which then writes back `vocdoni_member_id`.
    # No Vocdoni identifier is ever shown to or asked of an admin.
    #
    # Why the field list is a constant
    # --------------------------------
    # It mirrors the Vocdoni memberbase schema (ARCHITECTURE §4c) exactly, so it
    # can be relied upon by the credential picker, the CSV template and the CSV
    # importer without any of them triggering an API call.
    class CensusMember < SecureElections::ApplicationRecord
      self.table_name = "decidim_vocdoni_census_members"

      # Upstream field id => local column. The API speaks camelCase.
      FIELD_ATTRIBUTES = {
        "name" => :name,
        "surname" => :surname,
        "email" => :email,
        "phone" => :phone,
        "memberNumber" => :member_number,
        "nationalId" => :national_id,
        "birthDate" => :birth_date,
        "weight" => :weight
      }.freeze

      FIELDS = FIELD_ATTRIBUTES.keys.freeze

      # Fields that can carry a one-time code. `twoFaFields` is derived from
      # these; see {Decidim::SecureElections::Election::TWO_FA_METHODS}.
      TWO_FA_FIELDS = %w(email phone).freeze

      # Fields the Vocdoni memberbase treats as unique identifiers, in the
      # order it prefers for matching. A member without at least one of these
      # cannot be authenticated at vote time and, worse, is treated by
      # `POST /members` as a fresh record on every push: production hit exactly
      # this with a voter carrying only name+surname, and each retry of the
      # publish job left more zombie member ids in the memberbase before the
      # dupe error surfaced.
      #
      # Kept in sync with `PublishElectionJob::MEMBER_IDENTITY_FIELDS` (that
      # constant reads this one).
      IDENTITY_FIELDS = %w(memberNumber nationalId email phone).freeze

      # Fields an election may authenticate on. Neither the 2FA-capable fields
      # nor `weight` belong here: the first two are a second factor rather than
      # a credential, and voting power identifies nobody.
      CREDENTIAL_FIELDS = (FIELDS - TWO_FA_FIELDS - %w(weight)).freeze

      # The Vocdoni app caps credentials at three, and so do we: past that the
      # marginal security is nil and the odds of a voter mistyping something
      # are not.
      MAX_CREDENTIALS = 3

      # Fields the admin may fill in. `weight` is edited through its own
      # column, shown only for a weighted election.
      EDITABLE_FIELDS = (FIELDS - %w(weight)).freeze

      belongs_to :election,
                 foreign_key: "decidim_vocdoni_election_id",
                 class_name: "Decidim::SecureElections::Election",
                 inverse_of: :census_members

      before_validation :normalize_blanks

      validates :weight, numericality: { only_integer: true, greater_than: 0 }
      validates :email,
                format: { with: URI::MailTo::EMAIL_REGEXP },
                allow_blank: true
      validate :identifiable

      delegate :editable?, :on_chain?, to: :election, allow_nil: true

      default_scope { order(:surname, :name, :id) }

      scope :pushed, -> { where.not(vocdoni_member_id: nil) }

      # Members whose `attribute` is empty. Used to answer "12 people have no
      # email" *before* anything reaches the chain, which is the whole point of
      # holding the census locally. Blanks are normalized to NULL on save, so
      # a plain `IS NULL` is enough.
      scope :without_field, ->(attribute) { where(attribute => nil) }

      # @param field [String] an upstream field id, e.g. "memberNumber".
      # @return [Symbol, nil] the local column.
      def self.attribute_for(field)
        FIELD_ATTRIBUTES[field.to_s]
      end

      # @param fields [Array<String>] upstream field ids.
      # @return [Array<Symbol>] the local columns, unknown ids dropped.
      def self.attributes_for(fields)
        Array(fields).filter_map { |field| attribute_for(field) }
      end

      # Human name for a field, falling back to the id so an unknown field can
      # never blow up a view.
      def self.field_label(field)
        I18n.t(field, scope: "decidim.secure_elections.admin.census.member_fields", default: field.to_s)
      end

      # The value of an upstream field, whatever its local column is called.
      #
      # @param field [String] e.g. "birthDate".
      # @return [Object, nil]
      def value_for(field)
        attribute = self.class.attribute_for(field)
        attribute && public_send(attribute)
      end

      def write_field(field, value)
        attribute = self.class.attribute_for(field)
        public_send(:"#{attribute}=", value) if attribute
      end

      # Fields required by this member's election that this member does not
      # have. Empty means the member can be authenticated.
      #
      # `alternative_member_fields` — only "voter's choice" 2FA — are satisfied
      # by any one of them, so they are reported together or not at all.
      #
      # @return [Array<String>] upstream field ids.
      def missing_fields
        return [] if election.blank?

        missing = election.required_member_fields.reject { |field| value_for(field).present? }

        alternatives = election.alternative_member_fields
        missing += alternatives if alternatives.any? && alternatives.none? { |field| value_for(field).present? }

        missing.uniq
      end

      def complete?
        missing_fields.empty?
      end

      # Whatever is worth showing in a list: a full name, or the first
      # identifier that is filled in.
      def display_name
        full_name.presence || email.presence || phone.presence || member_number.presence ||
          national_id.presence || I18n.t("decidim.secure_elections.admin.census.members.unnamed")
      end

      def full_name
        [name, surname].compact_blank.join(" ")
      end

      # The payload for `POST /organizations/{addr}/members`.
      #
      # Blank values are dropped rather than sent as empty strings: the API
      # matches voters on these fields, and an empty string is not the same as
      # "not provided".
      #
      # @return [Hash] camelCase keys, as the API expects.
      def to_api_member
        FIELDS.each_with_object({}) do |field, payload|
          value = value_for(field)
          next if value.blank? && field != "weight"

          payload[field] = case field
                           when "birthDate" then value.to_date.iso8601
                           # `weight` MUST be sent as a string. The published
                           # TypeScript type says `weight?: number`, but an
                           # integer makes the backend fail to unmarshal the
                           # whole request and answer
                           # `{"error":"invalid JSON request body: missing
                           # members","code":40004}` — an error that names the
                           # wrong field entirely and sends you hunting through
                           # the array shape. Verified against staging: the same
                           # payload with `"1"` returns 200, with `1` returns
                           # 400. See ARCHITECTURE §4c.
                           when "weight" then value.to_s
                           else value
                           end
        end
      end

      private

      # An empty string is not a value. Normalizing here keeps the `missing`
      # scope a plain `IS NULL` check instead of a per-column `OR = ''`.
      def normalize_blanks
        EDITABLE_FIELDS.each do |field|
          attribute = self.class.attribute_for(field)
          value = public_send(attribute)
          next unless value.is_a?(String)

          public_send(:"#{attribute}=", value.strip.presence)
        end

        self.weight = 1 if weight.blank?
      end

      # A row with no identifier is not a person the memberbase can match: it
      # would be pushed as a fresh record on every retry (see
      # {IDENTITY_FIELDS}) and rejected at auth time as `census participant not
      # found`. Caught here so the admin sees "add an email or a member number"
      # instead of a duplicate cascade after publish.
      def identifiable
        return if IDENTITY_FIELDS.any? { |field| value_for(field).present? }

        errors.add(:base, :blank_member)
      end
    end
  end
end

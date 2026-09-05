# frozen_string_literal: true

module Decidim
  module SecureElections
    # An election run on the Vocdoni protocol.
    #
    # A Decidim election maps to a single Vocdoni *process*; each of its
    # questions is a separate Vochain election underneath (see ARCHITECTURE §1).
    #
    # The record has two independent notions of "published":
    #
    # * `published_at` (Decidim::Publicable) — whether the election is listed on
    #   the public side of Decidim. Reversible.
    # * `vocdoni_process_id` — whether the election exists on chain. Written by
    #   Decidim::SecureElections::PublishElectionJob and **irreversible**: once set, the
    #   election can no longer be edited.
    class Election < SecureElections::ApplicationRecord
      include Decidim::Publicable
      include Decidim::SoftDeletable
      include Decidim::Traceable
      include Decidim::Loggable
      include Decidim::Resourceable
      include Decidim::HasComponent
      include Decidim::TranslatableResource
      include Decidim::TranslatableAttributes
      include Decidim::Searchable
      include Decidim::HasReference
      include Decidim::FilterableResource

      # Lifecycle of the on-chain process, mirroring Vocdoni's ProcessStatus but
      # kept lowercase locally (the API speaks uppercase, see `upstream_status`).
      #
      # draft      — not on chain yet, fully editable
      # publishing — a PublishElectionJob is in flight
      # ready      — on chain and accepting votes
      # paused     — on chain, voting temporarily halted
      # ended      — on chain, voting closed
      # results    — tally published on chain
      # canceled   — process aborted on chain
      STATUSES = %w(draft publishing ready paused ended results canceled).freeze

      # Statuses in which the process exists on chain and can still change.
      LIVE_STATUSES = %w(ready paused).freeze

      # The API's vocabulary is slightly wider than this column's: a live
      # process reports `ONGOING`, which is what the module calls `ready`.
      UPSTREAM_STATUS_ALIASES = { "ongoing" => "ready" }.freeze

      # Member fields that can be used as a *credential* — that is, a value the
      # voter types to prove they are on the census. Email and phone are
      # deliberately absent: they are a second factor, not a credential
      # (ARCHITECTURE §4c, member fields table), and `weight` identifies nobody.
      #
      # Kept as a constant rather than a live API read so that the census form
      # never triggers a request (ARCHITECTURE §0.5).
      AUTH_FIELDS = SecureElections::CensusMember::CREDENTIAL_FIELDS

      # Fields that can additionally carry a one-time code. An empty
      # `census_two_fa_fields` means auth-only: the CSP token is already
      # verified and the browser skips `authStep1`.
      TWO_FA_FIELDS = SecureElections::CensusMember::TWO_FA_FIELDS

      # The admin picks one of these; `census_two_fa_fields` is derived from it
      # and is the only thing stored. The mapping is the Vocdoni app's
      # (`VoterAuthentication/utils.ts`) and must not drift from it.
      TWO_FA_METHODS = {
        "off" => [],
        "email" => %w(email),
        "sms" => %w(phone),
        "voter_choice" => %w(email phone)
      }.freeze

      # WEAK / MID / STRONG, using the app's exact rule
      # (`VoterAuthentication/SecurityLevel.tsx#getSecurityLevel`).
      SECURITY_LEVELS = %w(weak mid strong).freeze

      # Results are either shown as votes arrive or only once the election ends.
      # `per_question` is deliberately excluded — vd's protocol does not support it.
      RESULTS_AVAILABILITIES = %w(real_time after_end).freeze

      component_manifest_name "vocdoni"

      has_many :questions,
               foreign_key: "decidim_vocdoni_election_id",
               class_name: "Decidim::SecureElections::Question",
               inverse_of: :election,
               dependent: :destroy

      has_many :answers, through: :questions, source: :answers

      # The census. Decidim owns it: these rows are collected here and pushed
      # upstream by the publish job, which then writes back each member's
      # `vocdoni_member_id`. No Vocdoni identifier is ever entered by hand.
      has_many :census_members,
               foreign_key: "decidim_vocdoni_election_id",
               class_name: "Decidim::SecureElections::CensusMember",
               inverse_of: :election,
               dependent: :destroy

      translatable_fields :title, :description

      validates :title, presence: true
      validates :status, inclusion: { in: STATUSES }
      validates :results_availability, inclusion: { in: RESULTS_AVAILABILITIES }
      validate :end_at_after_start_at

      scope :on_chain, -> { where.not(vocdoni_process_id: nil) }
      scope :off_chain, -> { where(vocdoni_process_id: nil) }
      scope :with_status, ->(*values) { where(status: values.flatten.compact_blank) }
      scope :upcoming, -> { published.on_chain.where(start_at: Time.current..) }
      scope :ongoing, -> { published.on_chain.with_status("ready", "paused").where(end_at: Time.current..) }
      scope :finished, -> { published.on_chain.where(end_at: ..Time.current).or(published.on_chain.with_status("ended", "results")) }

      # `datetime` is what global search orders and filters results by. It is
      # `published_at` rather than `start_at` because an election that starts
      # when it is published has no start time at all, and a null there would
      # sort every such election to one end of every result page.
      searchable_fields({
                          A: :title,
                          D: :description,
                          datetime: :published_at,
                          participatory_space: { component: :participatory_space }
                        },
                        index_on_create: ->(election) { election.visible? },
                        index_on_update: ->(election) { election.visible? })

      STATUSES.each do |value|
        define_method(:"#{value}?") { status == value }
      end

      def presenter
        Decidim::SecureElections::ElectionPresenter.new(self)
      end

      def self.log_presenter_class_for(_log)
        Decidim::SecureElections::AdminLog::ElectionPresenter
      end

      # Maps an upstream status onto one this column accepts.
      #
      # @param value [String, nil] the API's status, e.g. "READY" or "ONGOING"
      # @return [String, nil] a member of STATUSES, or nil when unrecognised
      def self.normalize_status(value)
        status = value.to_s.downcase.presence
        return nil if status.blank?

        status = UPSTREAM_STATUS_ALIASES.fetch(status, status)
        STATUSES.include?(status) ? status : nil
      end

      # Whether the election still exists only in Decidim.
      def editable?
        vocdoni_process_id.blank?
      end

      # Whether the election has been written to the blockchain.
      def on_chain?
        vocdoni_process_id.present?
      end

      # The status as the API expects it.
      def upstream_status
        status.to_s.upcase
      end

      # Whether the on-chain process is currently paused. Task 5 will wire
      # this against the sequencer status field; for now it is a stub so
      # the Dashboard's "Start election" button visibility can be tested
      # without the chain running.
      def paused?
        status == "paused"
      end

      # Has voting opened yet on chain? Three semantic states, matching
      # the three ways `manual_start` and `start_at` can combine:
      #
      # - `manual_start = true` → the process is born paused; it has
      #   "started" the moment the admin clicks Start (status advances
      #   from `paused` to `ready` or beyond).
      # - `manual_start = false, start_at blank` → the process opens on
      #   publish; started iff the election is on chain.
      # - `manual_start = false, start_at set` → scheduled start; started
      #   once the clock has passed `start_at`.
      def started?
        return false unless on_chain?
        return LIVE_STATUSES.include?(status) || %w(ended results).include?(status) if manual_start?
        return true if start_at.blank?

        start_at <= Time.current
      end

      def finished?
        return true if %w(ended results canceled).include?(status)

        end_at.present? && end_at <= Time.current
      end

      def ongoing?
        started? && !finished? && ready?
      end

      # ---------------------------------------------------------------------
      # Display state
      #
      # `status` is the *upstream* vocabulary and it is a trap in the admin: a
      # process that is open and taking votes reports `ready`, which to a
      # Decidim administrator reads "prepared, not started". Leading with it
      # made a live election look dormant on every admin screen at once.
      #
      # The display state is what a person should read. It is the same
      # derivation the public side already uses, so the admin and the
      # participant never disagree about whether voting is open, and it is
      # deliberately *derived* rather than stored — there is nothing to keep in
      # sync and nothing to migrate.
      # ---------------------------------------------------------------------

      # @return [Symbol] one of :draft, :publishing, :scheduled, :ongoing,
      #   :paused, :ended, :results, :canceled
      def display_state
        Decidim::SecureElections::ElectionStatusCell.state_for(self)
      end

      # When voting actually began, as opposed to when it was scheduled to.
      #
      # `start_at` is authoritative whenever the admin picked a moment. When
      # they chose "start when published" the column is NULL by design
      # (ARCHITECTURE §2.3), and the moment voting opened is the moment the
      # process reached the chain. There is no column for that (ARCHITECTURE §4b),
      # so it is read back from the `setup` entry the publish command writes to
      # the action log — the same record the admin log renders.
      #
      # @return [ActiveSupport::TimeWithZone, nil] nil while the election has
      #   neither a scheduled start nor a publication to point at.
      def started_at
        return start_at if start_at.present?
        return nil unless on_chain? || publishing?

        setup_requested_at
      end

      # ---------------------------------------------------------------------
      # Census
      # ---------------------------------------------------------------------

      # An election with neither a credential nor a second factor authenticates
      # nobody — publishing it would either fail upstream or, worse,
      # enfranchise every member of the organization. It is easy to arrive at by
      # accident, so it is checked three times: here, in the census form, and
      # again in the publish job just before anything is written on chain.
      def census_configured?
        auth_fields.any? || two_fa_fields.any?
      end

      def auth_fields
        Array(census_auth_fields).compact_blank
      end

      def two_fa_fields
        Array(census_two_fa_fields).compact_blank
      end

      # Empty two-factor fields mean the CSP token returned by `authStep0` is
      # already verified and the voting page skips `authStep1`.
      def auth_only?
        two_fa_fields.empty?
      end

      # Which of `off` / `email` / `sms` / `voter_choice` the stored
      # `census_two_fa_fields` corresponds to. Derived rather than stored so
      # that the column stays the single source of truth for the API payload.
      def two_fa_method
        TWO_FA_METHODS.key(two_fa_fields.sort) || (two_fa_fields.any? ? "voter_choice" : "off")
      end

      def two_fa?
        two_fa_fields.any?
      end

      # The app's rule, verbatim: 2FA wins, then a full set of credentials,
      # then everything else is weak.
      def security_level
        return "strong" if two_fa?

        auth_fields.size >= SecureElections::CensusMember::MAX_CREDENTIALS ? "mid" : "weak"
      end

      # ---------------------------------------------------------------------
      # Census membership
      #
      # Everything here is a local read. The point of holding the census in
      # Decidim is that "12 people have no email" can be said *before* anything
      # is written on chain, rather than surfacing as an opaque upstream 400.
      # ---------------------------------------------------------------------

      # Fields every member must have.
      #
      # Credentials are always required. A single second factor is required as
      # well: the voter has to supply the contact value at authentication time
      # and it has to match, so a member without it cannot vote (ARCHITECTURE
      # §4c-bis; a wrong contact is rejected with `40029 census participant not
      # found`).
      def required_member_fields
        fields = auth_fields
        fields += two_fa_fields if two_fa_fields.one?
        fields.uniq
      end

      # Fields of which at least one is required. Only "voter's choice" lands
      # here: a member reachable by email or by phone can complete the
      # challenge, so demanding both would refuse censuses that work.
      def alternative_member_fields
        two_fa_fields.many? ? two_fa_fields : []
      end

      # Every field the census depends on, in the order the admin picked them.
      def census_fields
        (auth_fields + two_fa_fields).uniq
      end

      # Columns worth showing in the members table: what the census needs, plus
      # a name to recognise people by, plus voting power when it counts.
      def census_columns
        columns = census_fields
        columns = %w(name surname) | columns unless columns.intersect?(%w(name surname))
        columns += ["weight"] if weighted?
        columns
      end

      def census_populated?
        census_members.exists?
      end

      # Brings `census_size` back in line with the member list.
      #
      # The count is denormalised because it is the turnout denominator: it is
      # read on every monitor refresh and on the public election page, where
      # counting rows each time would be a query per render.
      #
      # `update_column` is deliberate. This is a derived counter, not something
      # an admin typed, so running validations would let an election that is
      # invalid for an unrelated reason — a half-finished schedule, say — refuse
      # a number that is simply true; and touching `updated_at` would make an
      # election look edited when only its member list moved.
      #
      # From publication onwards this stops being the authority: the publish job
      # overwrites it with the size the network reports for the census it built.
      def refresh_census_size!
        update_column(:census_size, census_members.count) # rubocop:disable Rails/SkipsModelValidations
      end

      # Members that cannot be authenticated as configured.
      def incomplete_census_members
        required = SecureElections::CensusMember.attributes_for(required_member_fields)
        alternatives = SecureElections::CensusMember.attributes_for(alternative_member_fields)
        return census_members.none if required.none? && alternatives.none?

        table = SecureElections::CensusMember.arel_table
        condition = required.map { |attribute| table[attribute].eq(nil) }.reduce(:or)

        if alternatives.any?
          all_blank = alternatives.map { |attribute| table[attribute].eq(nil) }.reduce(:and)
          condition = condition ? condition.or(all_blank) : all_blank
        end

        census_members.where(condition)
      end

      # How many members are missing each required field, e.g.
      # `{"email" => 12}`. Only non-zero entries are returned.
      def census_members_missing_by_field
        counts = (required_member_fields + alternative_member_fields).index_with do |field|
          attribute = SecureElections::CensusMember.attribute_for(field)
          attribute ? census_members.without_field(attribute).count : 0
        end

        counts.select { |_field, count| count.positive? }
      end

      # Members the upstream group validation reported as incomplete.
      #
      # The API answers a bad group with
      # `{"data": {"missingData": ["<vocdoni member id>", …]}}` (HTTP 400, code
      # 40037). Those ids are only useful because members carry
      # `vocdoni_member_id`, which is what turns "validation failed" into
      # "Carol Tester and Dave Tester have no email".
      def census_members_reported_missing
        error = last_error
        ids = error.is_a?(Hash) ? Array(error.dig("data", "missingData")).compact_blank : []
        return census_members.none if ids.empty?

        census_members.where(vocdoni_member_id: ids)
      end

      # ---------------------------------------------------------------------
      # Wizard steps
      #
      # The admin is a sequence again, and a strict one: a step can only be
      # opened once every step before it is complete. There is exactly one
      # source of truth for that — the three places that enforce it (the
      # navigation, the controllers and the permission class) all ask the
      # methods below rather than reimplementing the rule.
      #
      # `monitor` is deliberately not one of the numbered steps. It is not
      # something an admin fills in; it is where they end up once the election
      # exists on chain.
      # ---------------------------------------------------------------------

      # The numbered steps, in order. The order *is* the prerequisite chain.
      WIZARD_STEPS = [:details, :questions, :census, :calendar, :publish].freeze

      # The four persistent tabs in the new admin IA.
      # `:main` maps to the election details/calendar screen (always reachable).
      # `:questions` maps to the ballot editor (reachable once `details_complete?`).
      # `:census` maps to the census screen (reachable once `questions_complete?`).
      # `:dashboard` maps to the dashboard/publish screen (always reachable).
      NAV_STEPS = [:main, :questions, :census, :dashboard].freeze

      # The steps that go read-only — rather than disappearing — once the
      # process is on chain. An admin must still be able to read what was
      # published.
      CONTENT_STEPS = [:details, :questions, :census, :calendar].freeze

      def details_complete?
        persisted? && translated_attribute(title).present?
      end

      def questions_complete?
        return false if questions.empty?

        questions.all?(&:complete?)
      end

      def calendar_complete?
        end_at.present?
      end

      # A census is only done when it identifies somebody *and* there is
      # somebody to identify. An election that reaches the chain with an empty
      # census cannot be fixed afterwards.
      def census_complete?
        census_configured? && census_populated? && !incomplete_census_members.exists?
      end

      # Everything the API needs before `POST /processes` can be attempted.
      def ready_for_setup?
        editable? && details_complete? && questions_complete? && census_complete? && calendar_complete?
      end

      # Is this step finished?
      #
      # `publish` is complete when the process exists on chain, which is the
      # only irreversible thing an admin can do here. `monitor` is never
      # "complete": it is a place, not a task.
      #
      # @param step [Symbol, String]
      # @return [Boolean]
      def step_complete?(step)
        case step.to_sym
        when :details then details_complete?
        when :questions then questions_complete?
        when :census then census_complete?
        when :calendar then calendar_complete?
        when :publish then on_chain?
        else false
        end
      end

      # Why this step cannot be opened, as a symbol, or nil when it can.
      #
      # The symbol is also the i18n key under
      # `decidim.secure_elections.admin.nav.reasons`, so the navigation, the controller
      # flash and the permission class all say the same sentence.
      #
      # @param step [Symbol, String]
      # @return [Symbol, nil]
      def step_blocker(step)
        case step.to_sym
        when :monitor then monitor_step_blocker
        when :publish then publish_step_blocker
        when :details then persisted? ? nil : :unsaved
        # Frozen, but never hidden: an admin has to be able to read what was
        # published, so an on-chain election unlocks every content step and the
        # screens render read-only.
        when *CONTENT_STEPS then on_chain? ? nil : missing_prerequisite(step.to_sym)
        end
      end

      # @param step [Symbol, String]
      # @return [Boolean]
      def step_reachable?(step)
        step_blocker(step).nil?
      end

      # Where an admin is sent when they ask for a step they cannot open. Always
      # the furthest thing they *can* work on, so the redirect moves them
      # forward rather than dumping them back at the beginning.
      #
      # @return [Symbol]
      def furthest_reachable_step
        return :monitor if on_chain? || publishing?

        WIZARD_STEPS.reverse.find { |step| step_reachable?(step) } || :details
      end

      # How many of the numbered steps are done. Rendered as progress.
      #
      # @return [Integer]
      def completed_steps_count
        WIZARD_STEPS.count { |step| step_complete?(step) }
      end

      # ---------------------------------------------------------------------
      # Results
      #
      # Everything here is a local read of `results_cache`. Nothing in this
      # class ever talks to the API.
      # ---------------------------------------------------------------------

      def results_available?
        results_cache.present? && results_synced_at.present?
      end

      def turnout
        return nil unless census_size.to_i.positive?

        (votes_count.to_f / census_size) * 100
      end

      # Last error recorded by a background job, if any.
      #
      # ASSUMPTION: the authoritative schema has no dedicated error column, so
      # jobs record their last failure under this reserved key of
      # `results_cache` rather than deviating from ARCHITECTURE §4b.
      def last_error
        results_cache["error"].presence if results_cache.is_a?(Hash)
      end

      def last_error_message
        last_error && last_error["message"]
      end

      # ---------------------------------------------------------------------
      # Filtering / search
      # ---------------------------------------------------------------------

      scope_search_multi :with_any_state, [:upcoming, :ongoing, :finished]

      ransacker_i18n_multi :search_text, [:title, :description]

      def self.ransackable_scopes(_auth_object = nil)
        [:with_any_state]
      end

      def self.ransackable_associations(_auth_object = nil)
        %w(questions answers)
      end

      def self.ransackable_attributes(_auth_object = nil)
        %w(search_text title description status published_at)
      end

      private

      # The instant the admin pressed "publish on the blockchain", which for an
      # election with no scheduled start is the instant voting opened. A single
      # indexed lookup, and only ever asked for by an on-chain election that has
      # no `start_at` of its own.
      def setup_requested_at
        return @setup_requested_at if defined?(@setup_requested_at)

        @setup_requested_at = Decidim::ActionLog
                              .where(resource: self, action: "setup")
                              .minimum(:created_at)
      end

      # Readable from the moment publication is attempted: the monitor is where
      # an admin watches the on-chain write land, or sees why it failed.
      def monitor_step_blocker
        return nil if on_chain? || publishing?

        :not_on_chain
      end

      # Nothing left to confirm once the process is on chain — the monitor takes
      # over, and the guard redirects there.
      def publish_step_blocker
        return :locked_on_chain if on_chain?

        missing_prerequisite(:publish)
      end

      # The first step before `step` that is not finished yet, named as the
      # reason `step` is locked. Nil when every prerequisite holds.
      #
      # @param step [Symbol]
      # @return [Symbol, nil]
      def missing_prerequisite(step)
        index = WIZARD_STEPS.index(step)
        return nil if index.nil?

        blocker = WIZARD_STEPS.first(index).find { |previous| !step_complete?(previous) }
        blocker && :"#{blocker}_incomplete"
      end

      def end_at_after_start_at
        return if end_at.blank? || start_at.blank?
        return if end_at > start_at

        errors.add(:end_at, :invalid)
      end
    end
  end
end

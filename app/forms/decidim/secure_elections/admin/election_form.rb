# frozen_string_literal: true

module Decidim
  module SecureElections
    module Admin
      # The Main tab: everything an admin decides *about* the election — its
      # title, its description, when it happens, and how results are shown.
      #
      # Merges what used to live in three separate forms (`ElectionForm`,
      # `ElectionCalendarForm`, and the ballot-wide `result_visibility` on
      # `ElectionQuestionsForm`) into a single form rendered as three
      # accordion cards. There is no separate Calendar step any more.
      #
      # Nothing here talks to the Vocdoni API. The election only reaches the
      # blockchain through `SetupForm`, which is a separate, explicit and
      # irreversible act.
      class ElectionForm < Decidim::Form
        mimic :election

        include Decidim::TranslatableAttributes

        translatable_attribute :title, String
        translatable_attribute :description, Decidim::Attributes::RichText

        attribute :stream_uri, String

        # Calendar card.
        #
        # `start_at` is optional in every case. Three meaningful states:
        #
        # - `manual_start = true` — the process is published in a paused
        #   state; the admin clicks "Start election" on the Dashboard to
        #   open voting. `start_at` is ignored in this mode.
        # - `manual_start = false, start_at blank` — the process opens the
        #   moment it is published on chain. This is the module's default.
        # - `manual_start = false, start_at present` — the process is
        #   scheduled to open at `start_at`.
        #
        # `end_at` is always required: upstream refuses a process without one,
        # and an election that never closes can never be tallied.
        attribute :manual_start, Boolean, default: false
        attribute :start_at, Decidim::Attributes::TimeWithZone
        attribute :end_at, Decidim::Attributes::TimeWithZone

        # Results availability card. Two-value radio group; upstream's
        # `per_question` is deliberately excluded because vd's protocol does
        # not support it.
        attribute :results_availability, String, default: "after_end"

        validates :title, translatable_presence: true
        validate :stream_uri_is_a_url
        validates :results_availability, inclusion: { in: Decidim::SecureElections::Election::RESULTS_AVAILABILITIES }
        # `end_at` presence is NOT required at Main-tab save time — an
        # admin creates a draft with a title and picks the schedule
        # later, either as they type in the Calendar accordion or right
        # before publishing. The Dashboard checklist and `SetupForm`
        # both check `calendar_complete?` (end_at present) before letting
        # the on-chain publish through.

        # Both comparisons are hand-rolled rather than left to the `date:`
        # validator. Its message interpolates the raw restriction, which
        # reached the admin as "must be after Mon, 27 Jul 2026 21:54:36 +0000"
        # — a timestamp in a format that appears nowhere else in Decidim, in
        # a time zone the admin never chose. The wording below says what is
        # wrong and prints the moment the same way every other date on the
        # screen is printed, in the organization's own zone.
        validate :start_at_before_end_at
        validate :start_at_in_the_future
        validate :end_at_in_the_future

        def map_model(election)
          self.stream_uri = election.stream_uri
          self.manual_start = election.manual_start
          self.start_at = election.start_at
          self.end_at = election.end_at
          self.results_availability = election.results_availability
        end

        def election
          @election ||= context[:election]
        end

        # Once the process exists on chain its payload is frozen upstream, so
        # the form must not pretend otherwise.
        def editable?
          election.nil? || election.editable?
        end

        # Compatibility shim for callers still asking about the old wizard's
        # Schedule step; the meaning is unchanged (end date is required and
        # a start date is optional).
        alias calendar_complete? end_at

        private

        def stream_uri_is_a_url
          return if stream_uri.blank?

          uri = URI.parse(stream_uri)
          raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) && uri.host.present?
        rescue URI::InvalidURIError
          errors.add(:stream_uri, :invalid)
        end

        def start_at_before_end_at
          return if start_at.blank? || end_at.blank?
          return if start_at < end_at

          errors.add(:start_at, :not_before_end_at, end_at: formatted(end_at))
        end

        # A start in the past is a typo, and it used to be accepted in silence:
        # the schedule saved, the publish checklist reported every item done,
        # and "what will be published" printed a start in 2020 without a word
        # about it — right up to the button that spends real tokens.
        #
        # It is only a mistake while the election can still be edited, for the
        # same reason the end time is. An election already on chain legitimately
        # has a start in the past, and re-validating one would make an existing
        # record unsaveable.
        def start_at_in_the_future
          return if start_at.blank? || !editable?
          return if start_at > Time.current

          errors.add(:start_at, :not_in_the_future, now: formatted(Time.current))
        end

        # An end time in the past is only a mistake while the election can
        # still be edited. Once it is on chain the record is read-only anyway.
        def end_at_in_the_future
          return if end_at.blank? || !editable?
          return if end_at > Time.current

          errors.add(:end_at, :not_in_the_future, now: formatted(Time.current))
        end

        # The format every other date in this admin is rendered in. `Time.zone`
        # is the organization's, set by Decidim for the request.
        def formatted(time)
          I18n.l(time.in_time_zone, format: :decidim_short)
        end
      end
    end
  end
end

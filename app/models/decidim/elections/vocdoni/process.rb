# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Vocdoni-specific state of a Decidim election, kept in the sidecar
      # `decidim_vocdoni_processes` table so upstream's `decidim_elections_elections`
      # stays untouched.
      #
      # See db/migrate/20260918150001_create_vocdoni_processes.rb for the
      # shape and the reasoning.
      class Process < ApplicationRecord
        self.table_name = "decidim_vocdoni_processes"

        STATES = %w(pending publishing published failed).freeze
        # The `twoFaFields` an attested census accepts: an attestation binds at most one contact.
        TWO_FA_FIELDS = [[], ["email"], ["phone"]].freeze
        # Metadata entry holding the encrypted signer key a rotation is registering with the SaaS.
        PENDING_SIGNER_KEY = "pending_attestation_signer_key"

        belongs_to :election,
                   class_name: "Decidim::Elections::Election",
                   foreign_key: "decidim_election_id",
                   inverse_of: :vocdoni_process

        has_many :issued_attestations,
                 class_name: "Decidim::Elections::Vocdoni::IssuedAttestation",
                 foreign_key: "decidim_vocdoni_process_id",
                 inverse_of: :process,
                 dependent: :delete_all

        validates :state, inclusion: { in: STATES }
        validates :vocdoni_process_id, uniqueness: true, allow_nil: true

        # Once the election on chain is anchored the draft is gone from SaaS
        # (a published process is not a draft any more), so `DELETE` no longer
        # applies. Only unpublished drafts need cleanup — that is, the sidecar
        # holds a `vocdoni_process_id` (the create step succeeded) but the
        # publish step never turned the row `state = "published"`. Without
        # this hook, destroying the Decidim election (which cascades here via
        # `has_one :vocdoni_process, dependent: :destroy`) would orphan the
        # draft on SaaS and eat one of the org's two draft slots — see
        # `40031 max drafts reached`.
        #
        # The DELETE runs inside the enclosing `Election#destroy` transaction:
        # if it raises the whole destroy rolls back and the admin gets to
        # retry, so we never end up with a Decidim election gone but its
        # SaaS draft still hanging around.
        before_destroy :delete_upstream_draft, if: :upstream_draft?

        scope :pending, -> { where(state: "pending") }
        scope :publishing, -> { where(state: "publishing") }
        scope :published, -> { where(state: "published") }
        scope :failed, -> { where(state: "failed") }

        def pending? = state == "pending"

        def publishing? = state == "publishing"

        def published? = state == "published"

        def failed? = state == "failed"

        # The second factor chosen on the Security tab, in the SaaS `twoFaFields` shape.
        def two_fa_fields = Array(metadata.to_h.dig("settings", "twofa_fields")).map(&:to_s)

        # Where the one-time code goes, "email" or "phone"; nil without a code.
        def contact_kind = two_fa_fields.first

        # The maxCensusSize an attested census declares for `eligible` voters: ceil(eligible × 1.2),
        # at least 1. Integer arithmetic, so 10 voters declare 12 and not 13.
        def self.attested_census_size(eligible) = [((eligible * 6) + 4) / 5, 1].max

        # The key of a voter in the voterId preimage, from the GlobalID `voter_uid` Decidim's census
        # access gives the booth: "user:<id>" for an internal user, "row:<id>" for a census row.
        def self.voter_key(voter_uid)
          gid = GlobalID.parse(voter_uid.to_s)
          case gid&.model_name
          when "Decidim::User" then "user:#{gid.model_id}"
          when "Decidim::Elections::Voter" then "row:#{gid.model_id}"
          else raise ArgumentError, "unknown voter_uid"
          end
        end

        # Draws the per-election signer key and voterId secret, once. Both are stored encrypted.
        def ensure_attestation_secrets!
          return if attestation_signer_key.present? && voter_id_secret.present?

          update!(
            attestation_signer_key: attestation_signer_key.presence || encryptor.encrypt(new_signer_key_hex),
            voter_id_secret: voter_id_secret.presence || encryptor.encrypt(SecureRandom.hex(32))
          )
        end

        # The private scalar of the election's attestation signer.
        def signer_private_key
          raise ArgumentError, "no attestation signer" if attestation_signer_key.blank?

          Attestation.b2i(Attestation.hex_to_bytes(encryptor.decrypt(attestation_signer_key)))
        end

        # The 0x address of the election's attestation signer.
        def signer_address = Attestation.bytes_to_hex(Attestation.address(signer_private_key))

        # Yields the address of a candidate signer key for the caller to register with the SaaS, and
        # signs with it only once the block returns. The candidate is stored (encrypted) before the
        # yield, so a retry after a crash re-registers the same key, a no-op for the SaaS.
        def rotate_attestation_signer!
          key_hex = pending_signer_key_hex || stage_pending_signer_key!
          address = Attestation.bytes_to_hex(Attestation.address(Attestation.b2i(Attestation.hex_to_bytes(key_hex))))
          begin
            yield address
          rescue ApiError => e
            # A rejection means the SaaS never took the candidate; a transient error may hide that it did.
            update_metadata! { |data| data.except(PENDING_SIGNER_KEY) } unless e.transient?
            raise
          end
          with_lock do
            self.metadata = metadata.except(PENDING_SIGNER_KEY)
            update!(attestation_signer_key: encryptor.encrypt(key_hex))
          end
          address
        end

        # voterId = HMAC-SHA256(secret, voter_key ‖ processId): stable for a voter within the election,
        # unlinkable across elections and meaningless to the SaaS.
        def voter_id_for(voter_uid)
          raise ArgumentError, "no voterId secret" if voter_id_secret.blank?
          raise ArgumentError, "no SaaS process id" if vocdoni_process_id.blank?

          secret = Attestation.hex_to_bytes(encryptor.decrypt(voter_id_secret))
          preimage = self.class.voter_key(voter_uid).b + Attestation.hex_to_bytes(vocdoni_process_id)
          OpenSSL::HMAC.digest("SHA256", secret, preimage)
        end

        # Counts one more attestation issued to voter_id (0x hex), one row per voterId. With a cap, the
        # check and the increment are one statement, so concurrent requests cannot overshoot it.
        #
        # @return [Boolean] false when voter_id already reached the cap and nothing was counted.
        def record_issued_attestation!(voter_id, cap: nil)
          now = Time.current
          sql = <<~SQL.squish
            INSERT INTO decidim_vocdoni_attestations (decidim_vocdoni_process_id, voter_id, issued_count, created_at, updated_at)
            VALUES (?, ?, 1, ?, ?)
            ON CONFLICT (decidim_vocdoni_process_id, voter_id) DO UPDATE
            SET issued_count = decidim_vocdoni_attestations.issued_count + 1, updated_at = EXCLUDED.updated_at
            #{"WHERE decidim_vocdoni_attestations.issued_count < ?" if cap}
            RETURNING id
          SQL
          binds = [id, voter_id, now, now, cap].compact
          IssuedAttestation.connection.exec_query(IssuedAttestation.sanitize_sql_array([sql, *binds])).any?
        end

        # Per-question upstream ids and chain-side statuses. Written by
        # PublishElectionJob after the process is on chain; read by the voter
        # booth and the results-sync job.
        #
        # Shape:
        #   [
        #     { "decidim_question_id" => 42,
        #       "vocdoni_question_id" => "0x…",
        #       "vocdoni_upstream_id" => "0x…",
        #       "vocdoni_status"      => "ready" },
        #     …
        #   ]
        def questions_metadata
          Array(metadata["questions"])
        end

        def questions_metadata=(list)
          self.metadata = metadata.merge("questions" => Array(list))
        end

        # A row is a "SaaS draft" — a process created via `POST /processes`
        # that never made it to `POST /processes/{id}/publish` — when it has
        # an upstream id but is not yet in `published` state on our side. A
        # row currently `publishing` is also considered a draft for this
        # purpose: from SaaS's perspective it is a draft until the async
        # publish job completes, and if the publish is failing we do want it
        # cleaned up.
        def upstream_draft?
          vocdoni_process_id.present? && !published?
        end

        # Best-effort DELETE against the SaaS. Runs in the enclosing
        # `Election#destroy` transaction: any raise rolls the destroy back.
        #
        # Codes we accept as success:
        # - 2xx: gone as requested.
        # - 404: already gone (a manual purge, a previous partial destroy).
        # - 40012 (`ErrDuplicateConflict`, "process already published and not
        #   in draft mode"): the process crossed onto the chain while our
        #   sidecar still said `publishing`. There is nothing to delete
        #   anymore — the destroy of the sidecar row is fine, though the
        #   on-chain process is not going anywhere.
        #
        # Anything else — a scope 40158, an auth 40001, a network flap, a
        # 5xx — is a real failure and MUST raise so the destroy rolls back.
        def delete_upstream_draft
          Decidim::Elections::Vocdoni::ApiClient.new.elections.delete(vocdoni_process_id)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          return if e.status == 404 || e.code == 40_012

          raise
        end

        # Records the last non-transient publish failure. Used by the dashboard
        # to surface something actionable instead of a stuck wizard.
        #
        # `data` keeps the SaaS structured error payload so the admin
        # sees the raw error context, not just the message.
        #
        # `keep_state` records the error without marking the process failed,
        # for a step whose failure leaves the rest of the election usable.
        def record_failure!(message, step: nil, code: nil, data: nil, keep_state: false)
          self.metadata = metadata.merge(
            "last_error" => {
              "message" => message.to_s,
              "step" => step.presence&.to_s,
              "code" => code,
              "data" => data.presence,
              "at" => Time.current.iso8601
            }.compact
          )
          self.last_error = message.to_s.truncate(255)
          self.state = "failed" unless keep_state
          save!
        end

        # Chain status changes that failed for one question of a
        # `per_question` election, keyed by Decidim question id (a string).
        # Each entry stays until that question reaches its status on chain, so
        # the admin dashboard keeps showing it while Decidim and the chain
        # disagree.
        def question_failures
          metadata["question_failures"].to_h
        end

        # Records the failure for the question as well as in `last_error`. The
        # process stays `published`: the other questions keep voting.
        # `retries` is `{ attempts:, gave_up: }` for a job that retries on its
        # own: the tries made so far and whether it stopped.
        def record_question_failure!(question_id, message, step:, code: nil, retries: {})
          with_lock do
            entry = { "message" => message.to_s, "step" => step.to_s, "code" => code,
                      "attempts" => retries[:attempts], "gave_up" => retries.fetch(:gave_up, false),
                      "at" => Time.current.iso8601 }.compact
            self.metadata = metadata.merge("question_failures" => question_failures.merge(question_id.to_s => entry))
            record_failure!(message, step:, code:, keep_state: true)
          end
        end

        def clear_question_failure!(question_id)
          return unless question_failures.has_key?(question_id.to_s)

          with_lock do
            self.metadata = metadata.merge("question_failures" => question_failures.except(question_id.to_s))
            save!
          end
        end

        private

        def encryptor = Decidim::AttributeEncryptor.new(secret: "vocdoni-attestation")

        def new_signer_key_hex = Attestation.i2b(SecureRandom.random_number(Attestation::N - 1) + 1).unpack1("H*")

        def pending_signer_key_hex
          encrypted = metadata.to_h[PENDING_SIGNER_KEY]
          encryptor.decrypt(encrypted) if encrypted.present?
        end

        def stage_pending_signer_key!
          key_hex = new_signer_key_hex
          update_metadata! { |data| data.merge(PENDING_SIGNER_KEY => encryptor.encrypt(key_hex)) }
          key_hex
        end

        # Rewrites metadata under a row lock, so a concurrent writer of another entry is not lost.
        def update_metadata!
          with_lock { update!(metadata: yield(metadata.to_h)) }
        end
      end
    end
  end
end

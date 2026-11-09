# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Csp
        # The CSP roots this deployment can sign with, from
        # `VOCDONI_CSP_ROOTS="id:hex,id:hex"`. Each process records the id of
        # the root it was published with and signs only with that one, so a
        # root is added (appended) for new processes and kept while any of its
        # processes is open. Roots live only in memory: `inspect`, `to_s`,
        # `as_json` and every error message show ids only.
        class Keyring
          ENTRY = /\A(?<id>\h{16}):(?<hex>\h{64})\z/

          # Ids of roots used outside production (z4 dev, staging). A process on
          # the LTS chain refuses to publish or sign with any of them.
          NON_PROD_ROOT_IDS = [].freeze

          # Public id of a root: the first 8 bytes of keccak(compressed pubkey),
          # in hex. Safe to log and store.
          def self.id_for(root)
            Crypto.keccak(Crypto.public_key(Crypto.b2i(root)))[0, 8].unpack1("H*")
          end

          def self.load(value)
            roots = {}
            value.to_s.split(",").map(&:strip).reject(&:empty?).each_with_index do |entry, index|
              id, root = parse_entry(entry, index)
              raise ConfigurationError, "VOCDONI_CSP_ROOTS: duplicate root id #{id}" if roots.has_key?(id)

              roots[id] = root
            end
            new(roots)
          end

          def self.parse_entry(entry, index)
            match = ENTRY.match(entry)
            raise ConfigurationError, "VOCDONI_CSP_ROOTS: entry #{index + 1} is not <16 hex id>:<64 hex root>" unless match

            id = match[:id].downcase
            root = [match[:hex]].pack("H*")
            raise ConfigurationError, "VOCDONI_CSP_ROOTS: root #{id} is not a valid secp256k1 scalar" unless Crypto.b2i(root).between?(1, Crypto::N - 1)
            raise ConfigurationError, "VOCDONI_CSP_ROOTS: id #{id} does not match its root" unless id_for(root) == id

            [id, root.freeze]
          end
          private_class_method :parse_entry

          def initialize(roots)
            @roots = roots.freeze
            freeze
          end

          def ids = @roots.keys

          def empty? = @roots.empty?

          # The root new processes are published with: the last entry.
          def newest_id
            raise RootMissing, "VOCDONI_CSP_ROOTS is not set" if empty?

            @roots.keys.last
          end

          # The 32-byte root with this id. Raises rather than falling back to
          # another root, since a different root means a different key.
          def fetch(id)
            @roots.fetch(id.to_s) { raise RootMissing, "no CSP root with id #{id}" }
          end

          # True when bytes equal any root, compared in constant time.
          def include_root?(bytes)
            @roots.values.any? { |root| bytes.bytesize == root.bytesize && OpenSSL.fixed_length_secure_compare(bytes, root) }
          end

          # Refuses non-production roots on the production (LTS) chain.
          def assert_prod_safe!(chain_id)
            return true unless Vocdoni.lts_chain_id?(chain_id)

            denied = ids & NON_PROD_ROOT_IDS
            return true if denied.empty?

            raise ConfigurationError, "non-production CSP root ids #{denied.join(", ")} on chain #{chain_id}"
          end

          def inspect = "#<#{self.class.name} ids=#{ids.inspect}>"
          alias to_s inspect

          def pretty_print(pp) = pp.text(inspect)

          def as_json(*) = { "ids" => ids }
        end
      end
    end
  end
end

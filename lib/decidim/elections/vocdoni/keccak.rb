# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Keccak-256 as Ethereum uses it (padding 0x01, not SHA3-256's 0x06), for OpenSSL builds
      # older than 3.2, which lack KECCAK-256. Plain Ruby and slow, fine for EIP-712's short inputs.
      module Keccak
        module_function

        RATE = 136
        MASK = (2**64) - 1
        ROUND_CONSTANTS = [
          0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
          0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
          0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
          0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
          0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
          0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
        ].freeze
        # Rotation of lane x + 5y.
        ROTATIONS = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14].freeze

        def digest(message)
          padded = message.b + "\x01".b + ("\x00".b * (-(message.bytesize + 1) % RATE))
          padded.setbyte(-1, padded.getbyte(-1) | 0x80)
          state = Array.new(25, 0)
          padded.unpack("Q<*").each_slice(RATE / 8) do |block|
            block.each_with_index { |lane, i| state[i] ^= lane }
            permute(state)
          end
          state.first(4).pack("Q<4")
        end

        def rotl(lane, bits) = ((lane << bits) | (lane >> (64 - bits))) & MASK

        # Keccak-f[1600] in place, lanes indexed x + 5y: theta, rho and pi, chi, iota.
        def permute(lanes)
          ROUND_CONSTANTS.each do |rc|
            c = Array.new(5) { |x| lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20] }
            25.times { |i| lanes[i] ^= c[(i + 4) % 5] ^ rotl(c[(i + 1) % 5], 1) }
            b = Array.new(25)
            25.times { |i| b[(i / 5) + (5 * (((2 * (i % 5)) + (3 * (i / 5))) % 5))] = rotl(lanes[i], ROTATIONS[i]) }
            25.times do |i|
              row = i - (i % 5)
              lanes[i] = b[i] ^ (~b[row + ((i + 1) % 5)] & b[row + ((i + 2) % 5)])
            end
            lanes[0] ^= rc
          end
        end
      end
    end
  end
end

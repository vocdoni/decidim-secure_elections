# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Builds the link that opens the static voting page.
    #
    # The voting page is not a Decidim route. It is a file shipped inside this
    # gem and served by the engine's own middleware
    # (`Decidim::Elections::Vocdoni::Engine::VOTE_PATH`), which is why it keeps working
    # when Rails is busy, when the theme changes and when the asset pipeline has
    # not been run. Everything it needs travels in its query string:
    #
    #   the public Vocdoni API base URL, from which it reads the process;
    #   the Mongo ObjectID of that process, public by construction;
    #   the participant's locale, so the page opens in the language they were
    #     already reading;
    #   optionally, where "back to the election" goes.
    #
    # Nothing else is passed, and in particular nothing about the *voter*: who
    # may vote is the Vocdoni census's answer, not Decidim's (ARCHITECTURE §3).
    #
    # The four fields are packed into a single `?v=` value rather than spelled
    # out, because spelled out they run to 169 characters of which two thirds
    # are percent escapes, and this link is read off paper, pasted into chat
    # windows and typed by hand. Packed, the same link is 103, and the one an
    # organiser emails — which needs no exit — is 44.
    #
    # **The packing is an abbreviation, not a secret.** The decoder is public
    # (`app/packs/src/decidim/elections/vocdoni/voter/link_code.js`), `.decode` below is
    # its Ruby twin, and everything it carries is public anyway. Nothing may be
    # added here on the assumption that it is hidden.
    module VotingPageUrl
      # The layout the voting page's decoder understands. Bump it only together
      # with `VERSION` in `link_code.js`, and only for a change that would
      # otherwise be misread — a link already in an inbox is decoded by whatever
      # build the voter's browser happens to fetch.
      VERSION = 1

      FLAG_INLINE_API = 0x01
      FLAG_LOCALE = 0x02
      FLAG_EXIT = 0x04
      ALL_FLAGS = FLAG_INLINE_API | FLAG_LOCALE | FLAG_EXIT

      # API bases worth a single byte, because one installation uses one of them
      # for every election it ever runs and it is otherwise the longest thing in
      # the link.
      #
      # **Append only, and never renumber.** A code is baked into every link
      # already handed out; reusing one would point an old link at a different
      # API. Anything not listed still works — it travels inline, and the link
      # is longer by its length plus one.
      #
      # Mirrored by `API_HOSTS` in `link_code.js`.
      API_HOSTS = {
        1 => "https://saas-api.vocdoni.net",
        2 => "https://saas-api-stg.vocdoni.net",
        3 => "https://saas-api-dev.vocdoni.net"
      }.freeze

      # A Vocdoni process id is a Mongo ObjectID — ARCHITECTURE §1.
      PROCESS_ID_PATTERN = /\A[0-9a-f]{24}\z/i
      PROCESS_ID_BYTES = 12

      # Reads a packed payload left to right, refusing to run off the end.
      #
      # Truncation is the interesting failure: a link that lost its tail to a
      # line break in an email would otherwise decode into a process id made
      # half of padding, and send a voter to authenticate against an election
      # that does not exist.
      class Reader
        # What a payload that ran out mid-field raises.
        class Truncated < StandardError; end

        def initialize(bytes)
          @bytes = bytes
          @at = 0
        end

        # The next `count` bytes.
        def take(count)
          raise Truncated if count.negative? || @at + count > @bytes.bytesize

          slice = @bytes.byteslice(@at, count)
          @at += count
          slice
        end

        # The next byte, as a number.
        def byte = take(1).getbyte(0)

        # A length-prefixed UTF-8 string.
        def sized = utf8(take(byte))

        # Everything that is left.
        def rest = utf8(take(@bytes.bytesize - @at))

        # True when nothing has been left unread.
        def done? = @at == @bytes.bytesize

        private

        # Bytes as a string, refusing anything that is not valid UTF-8 — the
        # same strictness as the voting page's `TextDecoder(…, { fatal: true })`.
        def utf8(bytes)
          value = bytes.dup.force_encoding(Encoding::UTF_8)

          raise Truncated unless value.valid_encoding?

          value
        end
      end

      module_function

      # The voting page link for an election, or nil when there is nothing to
      # link to.
      #
      # An election that has never been pushed on chain has no process to open,
      # and an installation with no `api_url` has nowhere to send the browser.
      # Both return nil so the caller can say so, rather than minting a link
      # that lands on a page which can only fail.
      #
      # @param election [Decidim::Elections::Vocdoni::Election] the election to open.
      # @param locale [String, Symbol, nil] the language to open in.
      # @param exit_path [String, nil] where "back to the election" goes. Leave
      #   it out for a link that is going into an email: there is no page behind
      #   it to go back to, and the link is shorter without it.
      # @return [String, nil] a root-relative URL.
      def build(election, locale: I18n.locale, exit_path: nil)
        encoded = encode(
          api_url: Decidim::Elections::Vocdoni.api_url,
          process_id: election.vocdoni_process_id,
          locale:,
          exit_path:
        )

        return if encoded.blank?

        "#{Decidim::Elections::Vocdoni::Engine::VOTE_PATH}?v=#{encoded}"
      end

      # Packs the fields into the `v` value.
      #
      # @param api_url [String, nil] the public API base URL.
      # @param process_id [String, nil] the 24-hex process id.
      # @param locale [String, Symbol, nil] a language tag.
      # @param exit_path [String, nil] a root-relative path.
      # @return [String, nil] base64url without padding, or nil when the fields
      #   cannot be packed.
      def encode(api_url:, process_id:, locale: nil, exit_path: nil)
        api = api_url.to_s.strip.sub(%r{/+\z}, "")
        process = process_id.to_s.strip

        return if api.blank? || !PROCESS_ID_PATTERN.match?(process)

        flags = 0
        body = binary
        code = API_HOSTS.key(api)

        if code
          body << byte(code)
        else
          flags |= FLAG_INLINE_API
          return unless append_sized(body, api)
        end

        body << [process].pack("H*")

        if locale.present?
          flags |= FLAG_LOCALE
          return unless append_sized(body, locale.to_s)
        end

        if exit_path.present?
          flags |= FLAG_EXIT
          # Last, and therefore needing no length of its own: whatever is left
          # over is the exit.
          body << exit_path.to_s.dup.force_encoding(Encoding::BINARY)
        end

        Base64.urlsafe_encode64(byte((VERSION << 4) | flags) + body, padding: false)
      end

      # Unpacks a `v` value, or nil when it is not one.
      #
      # This exists because the packing is *not* a secret and this module should
      # not pretend otherwise. It is deliberately as strict as `decodeLink` in
      # `link_code.js` — same version, same flags, no trailing bytes — so a link
      # either round-trips through both or through neither.
      #
      # @param value [String, nil] the `v` parameter.
      # @return [Hash, nil] `{ api:, process:, locale:, exit: }`.
      def decode(value)
        bytes = Base64.urlsafe_decode64(value.to_s)
        flags = header_flags(bytes)

        return if flags.nil?

        reader = Reader.new(bytes.byteslice(1..))
        api = flags.anybits?(FLAG_INLINE_API) ? reader.sized : API_HOSTS[reader.byte]
        process = reader.take(PROCESS_ID_BYTES).unpack1("H*")
        locale = reader.sized if flags.anybits?(FLAG_LOCALE)
        exit_path = reader.rest if flags.anybits?(FLAG_EXIT)

        return if api.blank? || !reader.done?

        { api:, process:, locale:, exit: exit_path }
      rescue ArgumentError, Reader::Truncated
        nil
      end

      # The flags of a payload this build knows how to read, or nil when the
      # version or the flags are not ones it wrote.
      def header_flags(bytes)
        return if bytes.bytesize < 2

        header = bytes.getbyte(0)
        flags = header & 0x0f

        return unless (header >> 4) == VERSION && flags.nobits?(~ALL_FLAGS)

        flags
      end

      # An empty binary string to accumulate into.
      def binary
        String.new(encoding: Encoding::BINARY)
      end

      # One byte.
      def byte(value)
        [value].pack("C")
      end

      # Appends a length-prefixed UTF-8 string, or answers false when it is too
      # long to carry a one-byte length.
      def append_sized(body, value)
        bytes = value.dup.force_encoding(Encoding::BINARY)

        return false if bytes.bytesize > 255

        body << byte(bytes.bytesize) << bytes

        true
      end

      private_class_method :header_flags, :binary, :byte, :append_sized
    end
  end
end
end

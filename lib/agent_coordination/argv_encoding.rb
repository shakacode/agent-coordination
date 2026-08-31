# frozen_string_literal: true

module AgentCoord
  module ArgvEncoding
    class InvalidArgumentError < StandardError; end

    module_function

    # Ruby tags ARGV with the locale encoding while every textual consumer in
    # agent-coordination expects UTF-8. Filesystem paths are byte strings, so
    # callers identify those indexes and keep them untouched.
    def normalize_argv(argv, raw_indexes: [])
      argv.each_with_index.map do |argument, index|
        raw_indexes.include?(index) ? argument.to_s : normalize_argument(argument.to_s)
      end
    end

    # BINARY means argv arrived without a declared source encoding, as it does
    # under LC_ALL=C, so valid UTF-8 bytes are re-tagged. Any declared source
    # encoding is a real claim about the bytes and is transcoded instead.
    def normalize_argument(argument)
      normalized =
        if argument.encoding == Encoding::ASCII_8BIT
          force_utf8(argument)
        else
          argument.encode(Encoding::UTF_8)
        end
      return normalized if normalized.valid_encoding?

      raise InvalidArgumentError, invalid_argument_message(argument)
    rescue EncodingError
      raise InvalidArgumentError, invalid_argument_message(argument)
    end

    def force_utf8(text)
      text.dup.force_encoding(Encoding::UTF_8)
    end

    def utf8_diagnostic(text)
      force_utf8(text).scrub
    end

    def invalid_argument_message(argument)
      "command-line argument must be valid UTF-8: #{utf8_diagnostic(argument)}"
    end
  end
end

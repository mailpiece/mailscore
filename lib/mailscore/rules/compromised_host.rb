module MailScore
  module Rules
    # Traces a web script leaves in mail it sends, as from a hacked site: the
    # script's own headers, and a script run as root, from eval'd code or in
    # a hidden path.
    class CompromisedHost < Rule
      NAME = "COMPROMISED_HOST"
      GROUP = "compromised"

      SYMBOLS = {
        "PHP_SCRIPT_HEADER" => [ 0.0, "Sent by a PHP script" ],
        "PHP_SCRIPT_AS_ROOT" => [ 0.0, "PHP script ran as root" ],
        "PHP_SCRIPT_EVAL" => [ 0.0, "Sent by eval'd PHP code" ],
        "SCRIPT_SOURCE_HEADER" => [ 0.0, "Sending script's source headers" ],
        "SCRIPT_HIDDEN_PATH" => [ 0.0, "Sending script in a hidden path" ]
      }.freeze

      SOURCE_HEADERS = %w[ X-Source X-Source-Args X-Source-Dir ].freeze
      EVAL = /eval\(\)'d code/
      # A path segment starting with a dot, but not . or .., or an
      # originating script's file name after its uid.
      HIDDEN = %r{/\.[^./]}
      HIDDEN_ORIGIN = %r{(?:\A\d+:|/)\.[^./]}

      def run(message, _envelope)
        origin = message.header("x-php-originating-script")
        script = message.header("x-php-script")
        source_args = message.header("x-source-args")
        hidden = [ [ script, HIDDEN ], [ origin, HIDDEN_ORIGIN ], [ source_args, HIDDEN ] ].find { |value, pattern| value&.match?(pattern) }&.first

        {
          "PHP_SCRIPT_HEADER" => origin || script,
          "PHP_SCRIPT_AS_ROOT" => (origin if origin&.start_with?("0:")),
          "PHP_SCRIPT_EVAL" => [ origin, script ].find { it&.match?(EVAL) },
          "SCRIPT_SOURCE_HEADER" => SOURCE_HEADERS.find { message.header(it) },
          "SCRIPT_HIDDEN_PATH" => hidden
        }.compact.map { |name, detail| Hit.new(name:, weight: SYMBOLS.fetch(name).first, detail: detail[0, 200]) }
      end
    end
  end
end

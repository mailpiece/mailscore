module MailScore
  module Rules
    # Plain ASCII text encoded in base64, which it never needs.
    class MimeBase64TextBogus < Rule
      NAME = "TEXT_IN_BASE64"
      WEIGHT = 1.0
      DESCRIPTION = "ASCII text part encoded in base64"

      def run(message, _envelope)
        if (part = message.content.text_parts.find { it.encoding == "base64" && it.text.ascii_only? && it.text.match?(/\S/) })
          Hit.new(name: NAME, weight: WEIGHT, detail: part.type)
        end
      end
    end
  end
end

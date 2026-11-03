module MailScore
  module Rules
    # HTML with no plain text alternative.
    class MimeHtmlOnly < Rule
      NAME = "HTML_ONLY"
      WEIGHT = 0.2
      DESCRIPTION = "HTML with no plain text part"

      def run(message, _envelope)
        types = message.content.text_parts.map(&:type)
        Hit.new(name: NAME, weight: WEIGHT) if types.include?("text/html") && !types.include?("text/plain")
      end
    end
  end
end

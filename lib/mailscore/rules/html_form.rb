module MailScore
  module Rules
    # A form in the mail itself, which most clients will not submit and
    # phishing uses to collect credentials.
    class HtmlForm < Rule
      NAME = "HTML_FORM"
      GROUP = "html"
      WEIGHT = 1.5
      DESCRIPTION = "HTML form in the message"

      def run(message, _envelope)
        if (form = message.content.html.flat_map(&:tags).find { it.name == "form" })
          Hit.new(name: NAME, weight: WEIGHT, detail: form["action"]&.strip)
        end
      end
    end
  end
end

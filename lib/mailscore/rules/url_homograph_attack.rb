module MailScore
  module Rules
    # A URL host spelled with look-alike letters from another script.
    class UrlHomographAttack < Rule
      NAME = "LINK_LOOKALIKE_DOMAIN"
      GROUP = "url"
      WEIGHT = 5.0
      DESCRIPTION = "Link uses look-alike letters"

      def run(message, _envelope)
        if (url = message.content.urls.find(&:homograph?))
          Hit.new(name: NAME, weight: WEIGHT, detail: url.host)
        end
      end
    end
  end
end

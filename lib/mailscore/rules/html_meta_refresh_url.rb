module MailScore
  module Rules
    # HTML that sends the reader to another page on its own.
    class HtmlMetaRefreshUrl < Rule
      NAME = "HTML_AUTO_REDIRECT"
      WEIGHT = 5.0
      DESCRIPTION = "The HTML redirects to a link by itself (meta refresh)"

      def run(message, _envelope)
        tag = message.content.html.flat_map(&:tags).find do |tag|
          tag.name == "meta" && tag["http-equiv"].to_s.strip.casecmp?("refresh") && tag["content"].to_s.match?(/url\s*=/i)
        end

        Hit.new(name: NAME, weight: WEIGHT, detail: tag["content"].strip) if tag
      end
    end
  end
end

module MailScore
  module Rules
    # A delivery or disposition report, always from a null sender. A
    # multipart/report weighs in full; a postmaster or mailer-daemon From,
    # bounce words in the Subject and a returned message weigh less, and two
    # of them are needed.
    class Bounce < Rule
      NAME = "BOUNCE"
      GROUP = "headers"
      WEIGHT = -0.1
      DESCRIPTION = "Delivery status or read receipt"

      REPORT_TYPES = %w[ delivery-status disposition-notification ].freeze
      SENDERS = %w[ postmaster mailer-daemon ].freeze
      SUBJECT = /\b(?:could not send message|couldn't be delivered|delivery failed|delivery failure|delivery report|delivery status|delivery warning|failure delivery|failure notice|hasn't been delivered|mail failure|returned mail|undeliverable|undelivered)\b/i
      RETURNED = %w[ message/rfc822 message/rfc822-headers text/rfc822 text/rfc822-headers ].freeze

      # Parts searched for a returned message, the message itself first.
      PARTS = 9

      def run(message, envelope)
        return unless envelope.null_sender?

        if message.content_type == "multipart/report" && REPORT_TYPES.include?(message.content_type_param("report-type"))
          hit 1.0, "DSN"
        elsif (sender = message.from_addresses.first&.split("@")&.first&.downcase) == "mdaemon" && message.header_values("x-mddsn-message").any?
          hit 1.0, "MDaemon"
        else
          heuristic(message, (sender if SENDERS.include?(sender)), message.subject.to_s.match?(SUBJECT))
        end
      end

      private
        def heuristic(message, sender, subject)
          if sender && subject
            hit 0.5, "#{sender}+subj"
          elsif sender || subject
            returned = [ message, *message.parts ].first(PARTS).map(&:content_type).find { RETURNED.include?(it) }

            if returned && sender
              hit 0.5, "#{sender}+#{returned}"
            elsif returned
              hit 0.2, "#{returned}+subj"
            end
          end
        end

        def hit(share, detail)
          Hit.new(name: NAME, weight: (WEIGHT * share).round(2), detail:)
        end
    end
  end
end

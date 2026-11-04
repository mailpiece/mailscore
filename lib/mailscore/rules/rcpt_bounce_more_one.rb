module MailScore
  module Rules
    # A bounce goes back to one sender: a null or postmaster sender to
    # several recipients is not one.
    class RcptBounceMoreOne < Rule
      NAME = "BOUNCE_MANY_RECIPIENTS"
      GROUP = "hfilter"
      WEIGHT = 1.5
      DESCRIPTION = "Bounce sent to several recipients"

      def run(_message, envelope)
        recipients = envelope.recipients.map(&:downcase).uniq

        if !envelope.trusted? && bounce?(envelope) && recipients.size > 1
          Hit.new(name: NAME, weight: WEIGHT, detail: "#{recipients.size} recipients")
        end
      end

      private
        def bounce?(envelope)
          envelope.null_sender? || envelope.mail_from.to_s.split("@").first.to_s.casecmp?("postmaster")
        end
    end
  end
end

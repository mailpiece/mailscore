module MailScore
  module Rules
    # The sole recipient is a trap address, or one of several with
    # +trap_allow_multiple_rcpts+. Only spammers write to traps, so the weight
    # is high, but below the suggested reject threshold of 15: an old address
    # turned trap still gets the odd stray. The detail never names the trap.
    class Trap < Rule
      NAME = "SENT_TO_TRAP"
      GROUP = "trap"
      WEIGHT = 10.0
      DESCRIPTION = "Sent to a trap address"

      def run(_message, envelope)
        Hit.new(name: NAME, weight: WEIGHT) if MailScore::Trap.new(@config, @database).trapped?(envelope)
      end
    end
  end
end

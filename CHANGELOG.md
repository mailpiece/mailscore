# Changelog

## 0.4.1

- A `trap_addresses` entry `@example.net` traps every address at that domain

## 0.4.0

- `/check` returns `headers`, the `X-Spam-` fields a caller adds to the message it hands on

## 0.3.0

- A reverse DNS lookup that failed, mailscore's or the caller's (`Reverse-DNS-Status: temporary_failure`), fires only `REVERSE_DNS_LOOKUP_FAILED`, not a missing name
- `Unconfirmed-Hostname` takes the PTR name that did not resolve back, never trusted as the client's name
- `REVERSE_DNS_NONE` and `HOSTNAME_UNKNOWN` weigh 0 by default, like `REVERSE_DNS_LOOKUP_FAILED`: reverse DNS is reported, never scored
- Groups renamed, `hfilter` to `hostname`, `rbl` to `dnsbl`, `surbl` to `uribl`, `neural` to `fasttext`: a `groups` setting naming an old one fails at boot as unknown
- `ATTACHMENT_DISGUISED_PROGRAM` (12.0) fires on a program attached under a harmless name, such as a Windows executable named `invoice.pdf`, found by its first bytes, in a `programs` group of its own, uncapped
- `SPAM_TEST_STRING` fires on the standard anti-spam test string in the subject, headers or any text part, and forces reject, whatever the score, while reject is on

## 0.2.0

- `groups` caps what a symbol group adds, six of them by default; `/symbols` gives each symbol's group
- `scores` sets any symbol's weight, or switches it off
- Shorteners, trusted redirectors, risky and archive extensions are bundled files a setting replaces
- The shorteners and trusted redirectors lists take the hosts of the sources credited in NOTICE
- SHORTENED_LINK_ONLY fires on 247 shorteners, not 19, and LINK_TEXT_MISMATCH no longer on a link through one
- A list file replaced at runtime is read again within 30 seconds
- `trap_fuzzy_weight`, `bayes_min_tokens`, `bayes_min_prob_strength` and a DNS list's `received_max_pos` are settings, each defaulting to its old value
- `dnsbl: recommended` and `uribl: recommended` ask a bundled set of DNS lists
- Each DNS list is probed for a name it should not list and skipped while it lists it

## 0.1.1

- `/check` returns each symbol's description; descriptions are short labels

## 0.1.0

- First release: a spam scoring daemon over HTTP

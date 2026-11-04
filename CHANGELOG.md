# Changelog

## Unreleased

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

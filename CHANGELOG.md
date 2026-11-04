# Changelog

## Unreleased

- `groups` caps what a symbol group adds, six of them by default; `/symbols` gives each symbol's group
- `scores` sets any symbol's weight, or switches it off
- Shorteners, trusted redirectors, risky and archive extensions are bundled files a setting replaces
- The shorteners and trusted redirectors lists take the hosts of the sources credited in NOTICE
- SHORTENED_LINK_ONLY fires on 247 shorteners, not 19, and LINK_TEXT_MISMATCH no longer on a link through one

## 0.1.1

- `/check` returns each symbol's description; descriptions are short labels

## 0.1.0

- First release: a spam scoring daemon over HTTP

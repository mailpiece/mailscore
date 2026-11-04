# Changelog

## Unreleased

- `groups` caps what a symbol group adds, six of them by default; `/symbols` gives each symbol's group
- `dnsbl: recommended` and `uribl: recommended` ask a bundled set of DNS lists
- Each DNS list is probed for a name it should not list and skipped while it lists it

## 0.1.1

- `/check` returns each symbol's description; descriptions are short labels

## 0.1.0

- First release: a spam scoring daemon over HTTP

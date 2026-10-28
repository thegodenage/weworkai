#!/usr/bin/env bash

usage() {
  printf 'Usage: %s [-h|--help] [--] [author]\n' "${0##*/}"
  printf 'Greets everyone reading the author'\''s posts (default author: thegodenage).\n'
}

die() {
  printf '%s: %s\n' "${0##*/}" "$1" >&2
  usage >&2
  exit 2
}

main() {
  local author=""
  local -a names=()

  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        names+=("$@")
        break
        ;;
      -?*) die "unknown option: $1" ;;
      *) names+=("$1") ;;
    esac
    shift
  done

  if ((${#names[@]} > 1)); then
    die "too many arguments"
  fi
  if ((${#names[@]} == 1)); then
    author="${names[0]}"
  fi

  printf 'Hello, everyone reading %s posts! 👋\n' "${author:-thegodenage}"
}

# Only run when executed, so sourcing doesn't change the caller's shell options or exit it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi

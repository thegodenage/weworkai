#!/usr/bin/env bash

# Sourcing defines nothing and changes nothing in the caller's shell; this script is meant to be executed.
if (return 0 2>/dev/null); then
  printf 'hello.sh: run this script instead of sourcing it\n' >&2
  return 0
fi

set -euo pipefail

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

main "$@"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [author]\n' "${0##*/}"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    usage >&2
    exit 2
    ;;
esac

if (($# > 1)); then
  usage >&2
  exit 2
fi

author="${1:-thegodenage}"

printf 'Hello, everyone reading %s posts! 👋\n' "$author"

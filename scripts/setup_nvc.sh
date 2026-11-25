#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool_root="$project_root/build/tools/nvc-1.23.1"
archive="$project_root/build/tools/nvc_1.23.1-1_amd64_ubuntu-24.04.deb"
checksum=836b86c93d7ac0fa6d6313b651c0409476f04f59718fb270515e6bc6232477cd
url=https://github.com/nickg/nvc/releases/download/r1.23.1/nvc_1.23.1-1_amd64_ubuntu-24.04.deb
if [[ -x "$tool_root/usr/bin/nvc" ]]; then
    "$tool_root/usr/bin/nvc" --version >/dev/null
    printf '%s\n' "$tool_root"
    exit 0
fi
if [[ "$(uname -m)" != x86_64 ]]; then
    echo 'The pinned NVC package requires x86_64 Linux.' >&2
    exit 1
fi
mkdir -p "$(dirname "$archive")"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --show-error --retry 2 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status
mkdir -p "$tool_root"
dpkg-deb --extract "$archive" "$tool_root"
"$tool_root/usr/bin/nvc" --version >&2
printf '%s\n' "$tool_root"

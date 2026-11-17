#!/bin/sh
# Stage the original universal Sheer release and its copyright notice.
# Optionally set SHEER_RELEASE_ZIP to build offline from the pinned release.
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: stage-sheer.sh EMPTY_STAGING_DIRECTORY" >&2
    exit 2
fi

destination=$1
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
mkdir -p "$destination"
if [ -n "$(ls -A "$destination")" ]; then
    echo "Sheer staging directory must be empty." >&2
    exit 1
fi

artifact_url=https://github.com/AzurLiu/sheer/releases/download/v1.3.1/Sheer.zip
archive_sha256=535da0249405becff2df79d351fe64a6a8ad03742e6c389b9a4805c76fa14598
scratch=$(mktemp -d)
trap '/bin/rm -R -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

if [ -n "${SHEER_RELEASE_ZIP:-}" ]; then
    archive=$SHEER_RELEASE_ZIP
else
    archive=$scratch/Sheer.zip
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 2 --connect-timeout 15 --max-time 180 --output "$archive" "$artifact_url"
fi
actual_hash=$(/usr/bin/shasum -a 256 < "$archive")
if [ "${actual_hash%% *}" != "$archive_sha256" ]; then
    echo "Sheer release SHA-256 mismatch." >&2
    exit 1
fi

/usr/bin/ditto -x -k "$archive" "$scratch/unpacked"
app=$scratch/unpacked/Sheer.app
/usr/bin/codesign --verify --strict --all-architectures \
    -R='identifier "io.github.sheer.Sheer" and certificate leaf = H"cf074a2905835c4e5e03b22d69f0b565f822ce7d"' "$app"
/usr/bin/lipo "$app/Contents/MacOS/Sheer" -verify_arch arm64 x86_64
/bin/cp "$script_dir/LICENSE.Sheer" "$destination/LICENSE.Sheer"
/usr/bin/ditto "$app" "$destination/Sheer.app"

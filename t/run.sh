#!/bin/sh
# Run t/list.t in the LMS Docker image (for its DBI/DBD::SQLite) against COPIES of a library:
#   t/run.sh <library.db> <persist.db>
# The files are copied first; the originals are not touched.
set -e
lib=$(realpath "$1"); persist=$(realpath "$2")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$lib" "$tmp/library.db"; cp "$persist" "$tmp/persist.db"
repo=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm --entrypoint perl -v "$repo":/repo:ro -v "$tmp":/db lmscommunity/lyrionmusicserver:9.2.0 \
	-I/lms/CPAN/arch/5.40/x86_64-linux-thread-multi -I/lms/CPAN/arch/5.40 \
	/repo/t/list.t /db/library.db /db/persist.db

#!/bin/sh
# Build the plugin zip for the version in RediscoverReleases/install.xml, point repo.xml at it, commit, tag, push
# and create the GitHub release. GitHub Pages (main branch) then serves repo.xml and the zip.
#   tools/release.sh            build, commit, tag, push, release
#   tools/release.sh --build    only build the zip and update repo.xml
set -e
cd "$(dirname "$0")/.."

repo=arigit/LMS-Rediscover-Your-Music
pages=https://arigit.github.io/LMS-Rediscover-Your-Music
version=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' RediscoverReleases/install.xml)
[ -n "$version" ] || { echo "no version in install.xml" >&2; exit 1; }
zip=releases/RediscoverReleases-$version.zip

if [ "$1" != "--build" ]; then
	git diff --quiet && git diff --cached --quiet || { echo "commit your changes first" >&2; exit 1; }
	git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "v$version is already tagged: bump the version" >&2; exit 1; }
fi

mkdir -p releases
rm -f "$zip"
# Fixed timestamps and order, so the same source gives the same zip.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r RediscoverReleases "$tmp/"
find "$tmp/RediscoverReleases" -exec touch -h -d '2026-01-01 00:00:00 UTC' {} +
(cd "$tmp" && find RediscoverReleases -print | LC_ALL=C sort | zip -X -q -@ "$OLDPWD/$zip")
sha=$(sha1sum "$zip" | cut -d' ' -f1)

cat > repo.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<extensions>
  <details>
    <title lang="EN">Rediscover Releases</title>
  </details>
  <plugins>
    <plugin name="RediscoverReleases" version="$version" minTarget="8.0.0" maxTarget="*">
      <title lang="EN">Rediscover Releases</title>
      <desc lang="EN">A Material skin home row of random releases that prefers albums with no recent plays, with genre, play history and rebuild settings.</desc>
      <category>database</category>
      <url>$pages/$zip</url>
      <sha>$sha</sha>
      <icon>$pages/RediscoverReleases/HTML/EN/plugins/RediscoverReleases/html/images/icon_svg.png</icon>
      <link>https://github.com/$repo</link>
      <creator>arigit</creator>
    </plugin>
  </plugins>
</extensions>
XML
echo "Built $zip (sha1 $sha)"

[ "$1" = "--build" ] && exit 0

git add repo.xml "$zip"
git commit -q -m "Release $version"
git tag -a "v$version" -m "Rediscover Releases $version"
git push -q origin HEAD "v$version"
gh release create "v$version" "$zip" --repo "$repo" --title "Rediscover Releases $version" \
	--notes "Install from the repository $pages/repo.xml (LMS: Settings > Manage Plugins > Additional Repositories)."
echo "Released v$version"

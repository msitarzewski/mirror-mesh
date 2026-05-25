# Why: install the notarized MirrorMesh.app from the GitHub Release into
# /Applications. The app is signed + notarized + stapled by release.yml, so
# Gatekeeper accepts it without user override.
#
# STATUS: NOT YET ACTIVE. No GitHub Release artifact exists yet for any version
# AND the notarization pipeline is blocked on a user-supplied DEVELOPMENT_TEAM
# (see scripts/release/README.md). `url` will 404 until release.yml attaches
# the first MirrorMesh-macos-arm64.zip. Maintainers: bump `version` to match
# the tag and rewrite `sha256` from `release.json` before publishing.
cask "mirrormesh" do
  version "0.3.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_JSON"

  url "https://github.com/msitarzewski/mirror-mesh/releases/download/v#{version}/MirrorMesh-macos-arm64.zip"
  name "MirrorMesh"
  desc "Local-only realtime telepresence research app (watermarked by default)"
  homepage "https://github.com/msitarzewski/mirror-mesh"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MirrorMesh.app"

  zap trash: [
    "~/Library/Preferences/ai.mirrormesh.MirrorMesh.plist",
    "~/Library/Application Support/MirrorMesh",
    "~/Library/Caches/ai.mirrormesh.MirrorMesh",
  ]
end

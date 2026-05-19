# Why: install the notarized MirrorMesh.app from the GitHub Release into
# /Applications. The app is signed + notarized + stapled by release.yml, so
# Gatekeeper accepts it without user override.
#
# Maintainer: replace `<user>/<repo>` with the actual GitHub owner/repo
# (e.g. `mirrormesh/mirror-mesh`). The `sha256` placeholder is rewritten by
# the release workflow at tag time (see release-artifacts/release.json).
cask "mirrormesh" do
  version "0.3.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_JSON"

  url "https://github.com/<user>/<repo>/releases/download/v#{version}/MirrorMesh-macos-arm64.zip"
  name "MirrorMesh"
  desc "Local-only realtime telepresence research app (watermarked by default)"
  homepage "https://github.com/<user>/<repo>"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MirrorMesh.app"

  zap trash: [
    "~/Library/Preferences/ai.mirrormesh.MirrorMesh.plist",
    "~/Library/Application Support/MirrorMesh",
    "~/Library/Caches/ai.mirrormesh.MirrorMesh",
  ]
end

# Why: install the prebuilt `mirrormesh-bench` CLI from the GitHub Release
# attached by .github/workflows/release.yml. No source build — Homebrew users
# don't want to wait for swift build on every install.
#
# STATUS: NOT YET ACTIVE. No GitHub Release artifact exists yet for any version;
# `url` will 404 until the release workflow attaches the first
# `mirrormesh-bench-macos-arm64.zip`. `sha256` and `version` are both
# placeholders the release workflow rewrites at tag time (see
# release-artifacts/release.json). Maintainers: bump `version` to match the
# tag and replace `sha256` with the value from `release.json` before publishing.
class MirrormeshBench < Formula
  desc "MirrorMesh — local-only realtime telepresence bench CLI"
  homepage "https://github.com/msitarzewski/mirror-mesh"
  version "0.3.0"
  url "https://github.com/msitarzewski/mirror-mesh/releases/download/v#{version}/mirrormesh-bench-macos-arm64.zip"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_JSON"
  license "AGPL-3.0-only"

  depends_on arch: :arm64
  depends_on macos: :sonoma # macOS 14+

  def install
    bin.install "mirrormesh-bench"
  end

  test do
    # Why: --help must succeed without a scenario file or camera permission.
    assert_match "mirrormesh-bench", shell_output("#{bin}/mirrormesh-bench --help 2>&1", 0)
  end
end

# Why: install the prebuilt `mirrormesh-bench` CLI from the GitHub Release
# attached by .github/workflows/release.yml. No source build — Homebrew users
# don't want to wait for swift build on every install.
#
# Maintainer: replace `<user>/<repo>` below with the actual GitHub owner/repo
# (e.g. `mirrormesh/mirror-mesh`). The `sha256` placeholder is rewritten by
# the release workflow (see release-artifacts/release.json) when a new tag
# is published.
class MirrormeshBench < Formula
  desc "MirrorMesh — local-only realtime telepresence bench CLI"
  homepage "https://github.com/<user>/<repo>"
  version "0.3.0"
  url "https://github.com/<user>/<repo>/releases/download/v#{version}/mirrormesh-bench-macos-arm64.zip"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_JSON"
  license "Apache-2.0"

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

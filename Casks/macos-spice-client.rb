# Homebrew cask for MacOS Spice Client. The release workflow updates `version` and
# `sha256` whenever a version tag is pushed.
#
#   brew tap pawelwiecaszek/macos-spice-client https://github.com/pawelwiecaszek/macos-spice-client
#   brew install --cask macos-spice-client
cask "macos-spice-client" do
  version "0.1.0"
  sha256 "6cbbf57cdaaa62cce9704b4bfdbc6a586b1ed8253e970ddca88e9e3b974c978b"

  url "https://github.com/pawelwiecaszek/macos-spice-client/releases/download/#{version}/MacOS-Spice-Client-#{version}.dmg"
  name "MacOS Spice Client"
  desc "Native SPICE remote display client for Proxmox VE and QEMU virtual machines"
  homepage "https://github.com/pawelwiecaszek/macos-spice-client"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "MacOS Spice Client.app"

  # The app is ad-hoc signed, not notarized: drop the download quarantine so Gatekeeper
  # doesn't refuse to open it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/MacOS Spice Client.app"]
  end

  zap trash: [
    "~/Library/Application Scripts/com.pawelwiecaszek.spiceclient",
    "~/Library/Containers/com.pawelwiecaszek.spiceclient",
  ]
end

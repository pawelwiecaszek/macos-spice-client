# Homebrew cask for MacOS Spice Client. The release workflow updates `version` and
# `sha256` whenever a version tag is pushed.
#
#   brew tap pawelwiecaszek/macos-spice-client https://github.com/pawelwiecaszek/macos-spice-client
#   brew install --cask macos-spice-client
cask "macos-spice-client" do
  version "0.1.1"
  sha256 "03f5dba926f9b21b926b194a6b8171d36d76b52b5695d3f530c048a3dbfec336"

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

  # The app is ad-hoc signed and not notarized. The download quarantine is deliberately
  # kept, so Gatekeeper still asks before the first launch (System Settings › Privacy &
  # Security › Open Anyway).
  caveats <<~EOS
    #{token} is ad-hoc signed and not notarized by Apple. On first launch macOS blocks it:
    open System Settings › Privacy & Security and click "Open Anyway".
  EOS

  zap trash: [
    "~/Library/Application Scripts/com.pawelwiecaszek.spiceclient",
    "~/Library/Containers/com.pawelwiecaszek.spiceclient",
  ]
end

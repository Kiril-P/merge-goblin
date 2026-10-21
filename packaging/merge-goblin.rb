# Homebrew cask for the Merge Goblin. The release workflow fills in version and sha256;
# scripts/update-tap.sh copies the result into the tap (Kiril-P/homebrew-tap).
cask "merge-goblin" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Kiril-P/merge-goblin/releases/download/v#{version}/MergeGoblin-#{version}.dmg"
  name "Merge Goblin"
  desc "Menu bar app that reviews GitHub pull requests with your AI subscription"
  homepage "https://github.com/Kiril-P/merge-goblin"

  depends_on macos: :sonoma

  app "Merge Goblin.app"
  # the engine ships inside the app; this puts its `goblin` command on the PATH
  binary "#{appdir}/Merge Goblin.app/Contents/Resources/engine/bin/goblin"

  zap trash: [
    "~/.goblin",
    "~/Library/LaunchAgents/com.*.goblin.bar.plist",
  ]

  # Internal builds are not notarised yet. Remove this once releases are signed.
  caveats <<~EOS
    This build is not notarised. On first launch macOS will refuse to open it:
    open System Settings > Privacy & Security and click "Open Anyway" next to
    Merge Goblin. You only need to do this once per version.
  EOS
end

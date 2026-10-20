# Homebrew cask for the Merge Goblin. The release workflow fills in version and sha256;
# copy the result into the tap (Kiril-P/homebrew-tap, Casks/merge-goblin.rb).
cask "merge-goblin" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Kiril-P/merge-goblin/releases/download/v#{version}/MergeGoblin-#{version}.dmg"
  name "Merge Goblin"
  desc "Menu bar app that reviews GitHub pull requests with your AI subscription"
  homepage "https://github.com/Kiril-P/merge-goblin"

  depends_on macos: ">= :sonoma"

  app "Merge Goblin.app"
  # the engine ships inside the app; this puts its `goblin` command on the PATH
  binary "#{appdir}/Merge Goblin.app/Contents/Resources/engine/bin/goblin"

  zap trash: [
    "~/.goblin",
    "~/Library/LaunchAgents/com.*.goblin.bar.plist",
  ]
end

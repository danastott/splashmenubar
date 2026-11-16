cask "splashmenubar" do
  version "1.0.4"
  sha256 "d1e0d2a1d0aff3897dd3be8b3870019b0b740188d7800d0b0015a797b0f900c0"

  url "https://github.com/danastott/splashmenubar/releases/download/v#{version}/SplashMenuBar-#{version}.zip"
  name "Splash Menu Bar"
  desc "Menu bar app for Inco AI's splash local inference engine"
  homepage "https://github.com/danastott/splashmenubar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SplashMenuBar.app"

  uninstall quit: "com.danastott.splashmenubar"

  zap trash: [
    "~/.splashmenubar.json",
    "~/.splashmenubar.json.bak",
  ]
end

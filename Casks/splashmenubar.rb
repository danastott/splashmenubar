cask "splashmenubar" do
  version "1.0.9"
  sha256 "84a77b610e98e2c3ba4eb345bef83a8ed0c31a4a94bee258a9e8335c87d69887"

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

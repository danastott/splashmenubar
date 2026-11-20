cask "splashmenubar" do
  version "1.0.10"
  sha256 "62f52578b6beb9d78e70970ca891c3c04cf4a3dc0b36ecffc293209cb7e8d0c4"

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

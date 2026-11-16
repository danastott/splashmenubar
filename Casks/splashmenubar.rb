cask "splashmenubar" do
  version "1.0.3"
  sha256 "962aa37da0c3c4dd58718755a1e77e1943f7bbee792d31c1ce8ea9d798bb508d"

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

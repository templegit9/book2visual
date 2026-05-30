cask "book2visual" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/templegit9/book2visual/releases/download/v#{version}/Book2Visual-#{version}-macos.zip"
  name "Book2Visual"
  desc "Native SwiftUI control plane for the Book2Visual book-to-images pipeline"
  homepage "https://github.com/templegit9/book2visual"

  depends_on macos: :sonoma

  app "Book2Visual.app"

  zap trash: [
    "~/Library/Application Support/Book2Visual",
    "~/Library/Caches/com.book2visual.app",
    "~/Library/Containers/com.book2visual.app",
    "~/Library/Preferences/com.book2visual.app.plist",
    "~/Library/Saved Application State/com.book2visual.app.savedState",
  ]
end

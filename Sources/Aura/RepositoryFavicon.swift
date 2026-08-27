import AppKit
import SwiftUI

@MainActor
enum RepositoryFavicon {
    private static var images: [String: NSImage] = [:]
    private static var resolvedPaths: Set<String> = []

    static func image(for fileURL: URL?) -> NSImage? {
        guard let fileURL else { return nil }
        let root = repositoryRoot(for: fileURL)
        let cacheKey = root.path

        if resolvedPaths.contains(cacheKey) {
            return images[cacheKey]
        }

        resolvedPaths.insert(cacheKey)
        if let image = declaredFavicon(in: root) {
            images[cacheKey] = image
            return image
        }
        for relativePath in candidatePaths {
            let url = root.appendingPathComponent(relativePath)
            if let image = NSImage(contentsOf: url) {
                images[cacheKey] = image
                return image
            }
        }
        return nil
    }

    private static func declaredFavicon(in root: URL) -> NSImage? {
        let indexPaths = ["index.html", "app/index.html", "public/index.html", "src/index.html"]
        let linkPattern = #"(?i)<link\b[^>]*\brel=[\"'][^\"']*icon[^\"']*[\"'][^>]*>"#
        let hrefPattern = #"(?i)\bhref=[\"']([^\"']+)[\"']"#

        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern),
              let hrefRegex = try? NSRegularExpression(pattern: hrefPattern) else { return nil }

        for indexPath in indexPaths {
            let indexURL = root.appendingPathComponent(indexPath)
            guard let html = try? String(contentsOf: indexURL, encoding: .utf8) else { continue }
            let htmlRange = NSRange(html.startIndex..., in: html)

            for linkMatch in linkRegex.matches(in: html, range: htmlRange) {
                let link = (html as NSString).substring(with: linkMatch.range)
                let linkRange = NSRange(location: 0, length: (link as NSString).length)
                guard let hrefMatch = hrefRegex.firstMatch(in: link, range: linkRange),
                      hrefMatch.numberOfRanges > 1 else { continue }

                let href = (link as NSString).substring(with: hrefMatch.range(at: 1))
                for url in faviconURLs(for: href, indexURL: indexURL, root: root) {
                    if let image = NSImage(contentsOf: url) {
                        return image
                    }
                }
            }
        }
        return nil
    }

    private static func faviconURLs(for href: String, indexURL: URL, root: URL) -> [URL] {
        guard !href.hasPrefix("http://"),
              !href.hasPrefix("https://"),
              !href.hasPrefix("data:") else { return [] }

        let path = href.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        let decodedPath = path.removingPercentEncoding ?? path
        if decodedPath.hasPrefix("/") {
            let relativePath = String(decodedPath.dropFirst())
            return [
                indexURL.deletingLastPathComponent()
                    .appendingPathComponent("public")
                    .appendingPathComponent(relativePath),
                root.appendingPathComponent("public").appendingPathComponent(relativePath),
                root.appendingPathComponent(relativePath)
            ]
        }
        return [indexURL.deletingLastPathComponent().appendingPathComponent(decodedPath)]
    }

    private static func repositoryRoot(for fileURL: URL) -> URL {
        let fileManager = FileManager.default
        var directory = fileURL.deletingLastPathComponent().standardizedFileURL

        while directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    private static let candidatePaths = [
        "favicon.png", "favicon.svg", "favicon.ico",
        "public/favicon.png", "public/favicon.svg", "public/favicon.ico",
        "static/favicon.png", "static/favicon.svg", "static/favicon.ico",
        "assets/favicon.png", "assets/favicon.svg", "assets/favicon.ico"
    ]
}

struct RepositoryFaviconView: View {
    let fileURL: URL?
    var size: CGFloat = 18
    var fallbackColor: Color = .secondary

    var body: some View {
        if let image = RepositoryFavicon.image(for: fileURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "doc.text")
                .foregroundStyle(fallbackColor)
                .frame(width: size, height: size)
        }
    }
}

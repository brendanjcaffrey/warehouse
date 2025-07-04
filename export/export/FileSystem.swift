import AppKit

let WORKSPACE_DIR_KEY = "workspace"

let CONFIG_FILE_NAME = "config.yaml"
let EXPORT_LOG_FILE_NAME = "export.log"

class FileSystem {
    static func tryGetPersisted(key: String) -> Optional<URL> {
        if let data = UserDefaults.standard.data(forKey: key) {
            var bookmarkDataIsStale: ObjCBool = false

            do {
                let url = try (NSURL(resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &bookmarkDataIsStale) as URL)
                if bookmarkDataIsStale.boolValue {
                    return nil
                }
                if url.startAccessingSecurityScopedResource() {
                    return url
                }
            } catch {
                print(error.localizedDescription)
                return nil
            }
        }

        return nil
    }

    static func getUserSelectedFolder() -> Optional<URL> {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        let response = panel.runModal()
        if response == .OK, let directoryURL = panel.url {
            let newFileURL = directoryURL.appendingPathComponent("example.txt")
            let contents = "Hello, world!".data(using: .utf8)!

            do {
                try contents.write(to: newFileURL)
                print("File created at \(newFileURL.path)")
                try FileManager.default.removeItem(at: newFileURL)
            } catch {
                print("Failed to write file: \(error)")
            }
            return directoryURL
        }
        return nil
    }

    static func storeInBookmark(url: URL?, key: String) {
        do {
            if let url = url {
                let data = try url.bookmarkData(options: NSURL.BookmarkCreationOptions.withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.set(nil, forKey: key)
            }
        } catch {
            NSLog("Error storing bookmarks")
        }
    }
}

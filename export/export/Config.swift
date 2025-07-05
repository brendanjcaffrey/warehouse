import Foundation
import PostgresNIO
import Yams

struct SubpathCheck {
    var success: Bool
    var subpath: String?
    var errorMsg: String?
}

class Config {
    static func readLocalConfig(configFileURL: URL) throws -> [String: Any] {
        let data = try String(contentsOf: configFileURL, encoding: .utf8)
        let config = try Yams.load(yaml: data) as? [String: Any]
        return config!["local"]! as! [String : Any]
    }

    static func getMusicPath(configFileURL: URL) throws -> String {
        let localConfig = try readLocalConfig(configFileURL: configFileURL)
        return localConfig["music_path"] as! String
    }

    static func getArtworkPath(configFileURL: URL) throws -> String {
        let localConfig = try readLocalConfig(configFileURL: configFileURL)
        return localConfig["artwork_path"] as! String
    }

    static func checkMusicPath(workspaceDirURL: URL, configFileURL: URL) -> SubpathCheck {
        do {
            let musicPath = try getMusicPath(configFileURL: configFileURL)
            return checkPath(path: musicPath, workspaceDirURL: workspaceDirURL, pathType: "music_path")
        } catch {
            return SubpathCheck(success: false, errorMsg: error.localizedDescription)
        }
    }

    static func checkArtworkPath(workspaceDirURL: URL, configFileURL: URL) -> SubpathCheck {
        do {
            let artworkPath = try getArtworkPath(configFileURL: configFileURL)
            return checkPath(path: artworkPath, workspaceDirURL: workspaceDirURL, pathType: "artwork_path")
        } catch {
            return SubpathCheck(success: false, errorMsg: error.localizedDescription)
        }
    }

    static private func checkPath(path: String, workspaceDirURL: URL, pathType: String) -> SubpathCheck {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let workspaceURL = workspaceDirURL.standardizedFileURL

        if !url.path.hasPrefix(workspaceURL.path + "/") {
            return SubpathCheck(success: false, errorMsg: "\(pathType) \(path) is not a subdirectory of workspace_dir \(workspaceDirURL.relativeString) ")
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            return SubpathCheck(success: false, errorMsg: "\(pathType) \(path) does not exist")
        }

        let relativePath = url.path.replacingOccurrences(of: workspaceURL.path + "/", with: "")
        return SubpathCheck(success: true, subpath: relativePath)
    }

    static func getDatabaseConfig(configFileURL: URL) throws -> PostgresClient.Configuration? {
        let localConfig = try readLocalConfig(configFileURL: configFileURL)
        if localConfig["database_username"] == nil {
            print("Missing database_username from local config in \(configFileURL)")
            return nil
        }

        return PostgresClient.Configuration(
            host: "localhost",
            port: 5432,
            username: localConfig["database_username"] as? String ?? "",
            password: localConfig["database_password"] as? String ?? "",
            database: localConfig["database_name"] as? String ?? "",
            tls: .disable
        )
    }
}

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

    static func checkMusicPath(musicPath: String, trackLocation: URL) -> SubpathCheck {
        let trackFileURL = trackLocation.standardizedFileURL
        let musicDirURL = URL(fileURLWithPath: musicPath).standardizedFileURL

        guard trackFileURL.path.hasPrefix(musicDirURL.path + "/") else {
            return SubpathCheck(success: false, errorMsg: "track location \(trackLocation.relativeString) is not a subdirectory of music_path \(musicPath)")
        }

        let relativePath = trackFileURL.path.replacingOccurrences(of: musicDirURL.path, with: "")
        return SubpathCheck(success: true, subpath: relativePath)
    }

    static func getArtworkPath(configFileURL: URL) throws -> String {
        let localConfig = try readLocalConfig(configFileURL: configFileURL)
        return localConfig["artwork_path"] as! String
    }

    static func checkArtworkPath(workspaceDirURL: URL, configFileURL: URL) -> SubpathCheck {
        do {
            let artworkPath = try getArtworkPath(configFileURL: configFileURL)
            let artworkURL = URL(fileURLWithPath: artworkPath).standardizedFileURL
            let workspaceURL = workspaceDirURL.standardizedFileURL

            guard artworkURL.path.hasPrefix(workspaceURL.path + "/") else {
                return SubpathCheck(success: false, errorMsg: "artwork_path \(artworkPath) is not a subdirectory of workspace_dir \(workspaceDirURL.relativeString) ")
            }

            let relativePath = artworkURL.path.replacingOccurrences(of: workspaceURL.path + "/", with: "")
            return SubpathCheck(success: true, subpath: relativePath)
        } catch {
            return SubpathCheck(success: false, errorMsg: error.localizedDescription)
        }
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

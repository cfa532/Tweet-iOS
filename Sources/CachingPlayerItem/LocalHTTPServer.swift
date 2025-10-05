import Foundation
import Network

public class LocalHTTPServer: @unchecked Sendable {
    public static let shared = LocalHTTPServer()
    
    private var listener: NWListener?
    private var port: UInt16 = 8080
    private var mediaCache: [String: String] = [:] // mediaID -> cachePath
    private let queue = DispatchQueue(label: "LocalHTTPServer", qos: .userInitiated)
    
    private init() {}
    
    public func start() {
        queue.async { [weak self] in
            self?.startServer()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }
    
    public func registerMedia(mediaID: String, cachePath: String) {
        queue.async { [weak self] in
            self?.mediaCache[mediaID] = cachePath
            NSLog("DEBUG: [LocalHTTPServer] Registered media \(mediaID) -> \(cachePath)")
        }
    }
    
    public func getLocalURL(for mediaID: String) -> URL? {
        return URL(string: "http://localhost:\(port)/media/\(mediaID)/")
    }
    
    private func startServer() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: queue)
            NSLog("DEBUG: [LocalHTTPServer] Started on port \(port)")
        } catch {
            NSLog("DEBUG: [LocalHTTPServer] Failed to start: \(error)")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                let request = String(data: data, encoding: .utf8) ?? ""
                NSLog("DEBUG: [LocalHTTPServer] Received request: \(request.components(separatedBy: .newlines).first ?? "")")
                
                self?.handleRequest(request, connection: connection)
            }
            
            if isComplete {
                connection.cancel()
            }
        }
    }
    
    private func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: .newlines)
        guard let firstLine = lines.first else { return }
        
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 3 else { return }
        
        let method = components[0]
        let path = components[1]
        
        if method == "GET" || method == "HEAD" {
            handleGetRequest(path: path, method: method, connection: connection)
        } else {
            sendResponse(connection: connection, statusCode: 405, headers: [:], body: nil)
        }
    }
    
    private func handleGetRequest(path: String, method: String, connection: NWConnection) {
        // Parse path: /media/{mediaID}/{filename}
        let pathComponents = path.components(separatedBy: "/")
        guard pathComponents.count >= 3, pathComponents[1] == "media" else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            return
        }
        
        let mediaID = pathComponents[2]
        let filename = pathComponents.count > 3 ? pathComponents[3] : ""
        
        NSLog("DEBUG: [LocalHTTPServer] Handling request for mediaID: \(mediaID), filename: \(filename)")
        
        // Get cache path for this media
        guard let cachePath = mediaCache[mediaID] else {
            NSLog("DEBUG: [LocalHTTPServer] No cache found for mediaID: \(mediaID)")
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            return
        }
        
        // If no filename specified, serve the main playlist
        if filename.isEmpty {
            serveFile(path: cachePath, connection: connection, method: method)
            return
        }
        
        // For segments, look in the cache directory
        let cacheDir = URL(fileURLWithPath: cachePath).deletingLastPathComponent()
        let segmentPath = cacheDir.appendingPathComponent(filename).path
        
        if FileManager.default.fileExists(atPath: segmentPath) {
            serveFile(path: segmentPath, connection: connection, method: method)
        } else {
            NSLog("DEBUG: [LocalHTTPServer] File not found: \(segmentPath)")
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
        }
    }
    
    private func serveFile(path: String, connection: NWConnection, method: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            return
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let mimeType = getMimeType(for: path)
            
            let headers: [String: String] = [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "public, max-age=3600"
            ]
            
            if method == "HEAD" {
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: nil)
            } else {
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: data)
            }
            
            NSLog("DEBUG: [LocalHTTPServer] Served file: \(path) (size: \(data.count) bytes)")
        } catch {
            NSLog("DEBUG: [LocalHTTPServer] Failed to read file: \(error)")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
        }
    }
    
    private func getMimeType(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        default:
            return "application/octet-stream"
        }
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data?) {
        var response = "HTTP/1.1 \(statusCode) \(getStatusText(statusCode))\r\n"
        
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        
        response += "\r\n"
        
        let responseData = response.data(using: .utf8) ?? Data()
        var allData = responseData
        
        if let body = body {
            allData.append(body)
        }
        
        connection.send(content: allData, completion: .contentProcessed { error in
            if let error = error {
                NSLog("DEBUG: [LocalHTTPServer] Send error: \(error)")
            }
        })
    }
    
    private func getStatusText(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

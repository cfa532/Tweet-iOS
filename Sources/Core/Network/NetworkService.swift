import Foundation
import PromiseKit

class NetworkService {
    static let shared = NetworkService()
    private let baseURL: String
    private let session: URLSession
    
    private init() {
        self.baseURL = "http://your-server-url/"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    func invoke<T: Decodable>(_ method: String, _ args: Any...) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            // Create a strong reference to the continuation
            let strongContinuation = continuation
            
            // Create request
            var request = URLRequest(url: URL(string: baseURL)!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // Create request body
            let requestBody: [String: Any] = [
                "method": method,
                "args": args
            ]
            
            // Serialize request body
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            } catch {
                strongContinuation.resume(throwing: error)
                return
            }
            
            // Make request
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    strongContinuation.resume(throwing: error)
                    return
                }
                
                guard let data = data else {
                    strongContinuation.resume(throwing: NSError(domain: "NetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
                    return
                }
                
                do {
                    let result = try JSONDecoder().decode(T.self, from: data)
                    strongContinuation.resume(returning: result)
                } catch {
                    strongContinuation.resume(throwing: error)
                }
            }
            
            task.resume()
        }
    }
} 
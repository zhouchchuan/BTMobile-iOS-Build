import Foundation

actor APIClient {
    static let shared = APIClient()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func request<T: Decodable>(_ path:String, baseURL:String, token:String? = nil, method:String = "GET", body:Encodable? = nil) async throws -> T {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw URLError(.badURL) }
        var req = URLRequest(url:url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField:"Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField:"Content-Type")
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }
        let (data,res) = try await URLSession.shared.data(for:req)
        guard let http = res as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let obj = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            throw NSError(domain:"CustomerService", code:(res as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo:[NSLocalizedDescriptionKey:obj?["detail"] as? String ?? "请求失败"])
        }
        return try decoder.decode(T.self, from:data)
    }

    func uploadAttachment(_ path:String, baseURL:String, token:String, data:Data,
                          filename:String = "image.jpg", mime:String = "image/jpeg") async throws -> ChatMessage {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw URLError(.badURL) }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url:url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField:"Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using:.utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using:.utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using:.utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using:.utf8)!)
        req.httpBody = body
        let (responseData,res) = try await URLSession.shared.data(for:req)
        guard let http = res as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let obj = (try? JSONSerialization.jsonObject(with: responseData)) as? [String:Any]
            throw NSError(domain:"CustomerService", code:(res as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo:[NSLocalizedDescriptionKey:obj?["detail"] as? String ?? "附件上传失败"])
        }
        return try decoder.decode(ChatMessage.self, from:responseData)
    }
}

struct AnyEncodable: Encodable {
    private let encodeFn:(Encoder)throws->Void
    init(_ wrapped:Encodable){ encodeFn = wrapped.encode }
    func encode(to encoder:Encoder)throws{ try encodeFn(encoder) }
}

import Foundation

struct APIUser: Codable { let id:Int; let username:String; let role:String; let display_name:String; let slug:String? }
struct LoginResponse: Codable { let token:String; let user:APIUser }
struct ChatSession: Codable, Identifiable, Hashable {
    let id:Int; let token:String; let agent_id:Int; let agent_name:String; let ip:String; let user_agent:String; let visitor_name:String; let started_at:String; let last_message_at:String; let unread_agent:Int; let unread_visitor:Int; let last_message:ChatMessage?
}
struct ChatMessage: Codable, Identifiable, Hashable { let id:Int; let session_id:Int; let sender_type:String; let sender_id:Int?; let kind:String; let content:String; let created_at:String }
struct ChatMessagesResponse: Codable { let session:ChatSession; let messages:[ChatMessage] }
struct SendMessageBody: Codable { let content:String; let kind:String }
struct DeviceTokenBody: Codable { let token:String; let environment:String }

extension ISO8601DateFormatter {
    static let shared = ISO8601DateFormatter()
}

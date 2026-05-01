import Foundation
import GRDB

/// Generic persistence layer for chat messages stored in the local SQLite database.
/// Uses the `chat_messages` table (renamed from `task_chat_messages` in V3 migration).
enum ChatMessageStore {

    static func saveMessage(_ message: ChatMessage, context: String, sessionId: String? = nil) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        let sender = message.sender == .user ? "user" : "ai"
        let now = Date()
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO chat_messages
                        (taskId, messageId, sender, messageText, createdAt, updatedAt, backendSynced, session_id)
                        VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                    """,
                    arguments: [context, message.id, sender, message.text, message.createdAt, now, sessionId]
                )
            }
        } catch {
            logError("ChatMessageStore: Failed to save message", error: error)
        }
    }

    static func updateMessage(id: String, text: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE chat_messages SET messageText = ?, updatedAt = ? WHERE messageId = ?",
                    arguments: [text, Date(), id]
                )
            }
        } catch {
            logError("ChatMessageStore: Failed to update message", error: error)
        }
    }

    static func loadMessages(context: String, sessionId: String? = nil, limit: Int? = nil) async -> [ChatMessage] {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            return try await dbQueue.read { db in
                let sql: String
                let arguments: StatementArguments
                let sessionFilter = sessionId != nil ? " AND session_id = ?" : ""
                if let limit = limit {
                    // Fetch the N most recent messages for this context+session, then return in chronological order
                    sql = """
                        SELECT * FROM (
                            SELECT messageId, sender, messageText, createdAt
                            FROM chat_messages
                            WHERE taskId = ?\(sessionFilter)
                            ORDER BY createdAt DESC
                            LIMIT ?
                        ) ORDER BY createdAt ASC
                    """
                    if let sid = sessionId {
                        arguments = [context, sid, limit]
                    } else {
                        arguments = [context, limit]
                    }
                } else {
                    sql = """
                        SELECT messageId, sender, messageText, createdAt
                        FROM chat_messages
                        WHERE taskId = ?\(sessionFilter)
                        ORDER BY createdAt ASC
                    """
                    if let sid = sessionId {
                        arguments = [context, sid]
                    } else {
                        arguments = [context]
                    }
                }
                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)

                return rows.map { row in
                    ChatMessage(
                        id: row["messageId"],
                        text: row["messageText"],
                        createdAt: row["createdAt"],
                        sender: (row["sender"] as String) == "user" ? .user : .ai,
                        isStreaming: false,
                        isSynced: true
                    )
                }
            }
        } catch {
            logError("ChatMessageStore: Failed to load messages", error: error)
            return []
        }
    }

    /// Get the most recent ACP session ID stored for a conversation context.
    static func loadSessionId(context: String) async -> String? {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return nil }
        do {
            return try await dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT session_id FROM chat_messages
                    WHERE taskId = ? AND session_id IS NOT NULL AND session_id != ''
                    ORDER BY createdAt DESC
                    LIMIT 1
                """, arguments: [context])
                return row?["session_id"] as? String
            }
        } catch {
            logError("ChatMessageStore: Failed to load session ID", error: error)
            return nil
        }
    }

    static func clearMessages(context: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM chat_messages WHERE taskId = ?",
                    arguments: [context]
                )
            }
        } catch {
            logError("ChatMessageStore: Failed to clear messages", error: error)
        }
    }
}

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
        // Single-id wrapper kept for callers that don't need a multi-id chain.
        let sessionIds: [String]? = sessionId.map { [$0] }
        return await loadMessages(context: context, sessionIds: sessionIds, limit: limit)
    }

    /// Load messages for a `context`, optionally filtered to a SET of session IDs.
    /// Used by the recovery path so we can include history from prior sessionIds in
    /// the same logical conversation chain (a conversation's sessionId rolls over
    /// when an upstream session expires / hits a rate limit / the bridge restarts;
    /// without spanning the chain, the recovery preamble would only see post-rollover
    /// messages and lose the actual conversation context).
    static func loadMessages(context: String, sessionIds: [String]?, limit: Int? = nil) async -> [ChatMessage] {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            return try await dbQueue.read { db in
                let sessionFilter: String
                var args: [DatabaseValueConvertible?] = [context]
                if let ids = sessionIds, !ids.isEmpty {
                    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
                    sessionFilter = " AND session_id IN (\(placeholders))"
                    args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible? })
                } else {
                    sessionFilter = ""
                }
                let sql: String
                if let limit = limit {
                    // Fetch the N most recent messages for this context, then return in chronological order
                    sql = """
                        SELECT * FROM (
                            SELECT messageId, sender, messageText, createdAt
                            FROM chat_messages
                            WHERE taskId = ?\(sessionFilter)
                            ORDER BY createdAt DESC
                            LIMIT ?
                        ) ORDER BY createdAt ASC
                    """
                    args.append(limit)
                } else {
                    sql = """
                        SELECT messageId, sender, messageText, createdAt
                        FROM chat_messages
                        WHERE taskId = ?\(sessionFilter)
                        ORDER BY createdAt ASC
                    """
                }
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

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

"use client";

import { useState, useEffect, useRef, useCallback } from "react";

export interface ChatMessage {
  id: string;
  text: string;
  sender: "user" | "ai";
  isStreaming?: boolean;
  toolActivities?: { name: string; status: "running" | "completed" }[];
}

interface RelayHook {
  isConnected: boolean;
  isDesktopOnline: boolean;
  messages: ChatMessage[];
  sendMessage: (text: string) => void;
  isSending: boolean;
}

export function useDesktopRelay(token: string | null): RelayHook {
  const [isConnected, setIsConnected] = useState(false);
  const [isDesktopOnline, setIsDesktopOnline] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isSending, setIsSending] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const currentAiMessageId = useRef<string | null>(null);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || "";

  // Discover tunnel URL and connect
  const connect = useCallback(async () => {
    if (!token || !backendUrl) return;

    try {
      const res = await fetch(`${backendUrl}/api/relay/discover`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!res.ok) {
        setIsDesktopOnline(false);
        // Retry in 5s
        reconnectTimer.current = setTimeout(connect, 5000);
        return;
      }

      const { tunnel_url } = await res.json();
      if (!tunnel_url) {
        setIsDesktopOnline(false);
        reconnectTimer.current = setTimeout(connect, 5000);
        return;
      }

      // Connect WebSocket to tunnel
      const wsUrl = tunnel_url.replace(/^http/, "ws");
      const ws = new WebSocket(wsUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        setIsConnected(true);
        setIsDesktopOnline(true);
        // Request chat history
        ws.send(JSON.stringify({ type: "request_history" }));
      };

      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        handleMessage(msg);
      };

      ws.onclose = () => {
        setIsConnected(false);
        setIsDesktopOnline(false);
        setIsSending(false);
        wsRef.current = null;
        // Reconnect after 3s
        reconnectTimer.current = setTimeout(connect, 3000);
      };

      ws.onerror = () => {
        ws.close();
      };
    } catch {
      reconnectTimer.current = setTimeout(connect, 5000);
    }
  }, [token, backendUrl]);

  const handleMessage = useCallback((msg: Record<string, unknown>) => {
    switch (msg.type) {
      case "chat_history": {
        const history = (msg.messages as ChatMessage[]) || [];
        setMessages(history);
        break;
      }

      case "query_started": {
        const aiId = crypto.randomUUID();
        currentAiMessageId.current = aiId;
        setIsSending(true);
        setMessages((prev) => [
          ...prev,
          { id: aiId, text: "", sender: "ai", isStreaming: true },
        ]);
        break;
      }

      case "text_delta": {
        const id = currentAiMessageId.current;
        if (!id) break;
        setMessages((prev) =>
          prev.map((m) =>
            m.id === id ? { ...m, text: m.text + (msg.text as string) } : m
          )
        );
        break;
      }

      case "tool_activity": {
        const id = currentAiMessageId.current;
        if (!id) break;
        setMessages((prev) =>
          prev.map((m) => {
            if (m.id !== id) return m;
            const activities = [...(m.toolActivities || [])];
            const name = msg.name as string;
            const status = msg.status as string;
            if (status === "started") {
              activities.push({ name, status: "running" });
            } else {
              const idx = activities.findIndex(
                (a) => a.name === name && a.status === "running"
              );
              if (idx >= 0) activities[idx] = { name, status: "completed" };
            }
            return { ...m, toolActivities: activities };
          })
        );
        break;
      }

      case "result": {
        const id = currentAiMessageId.current;
        if (!id) break;
        setMessages((prev) =>
          prev.map((m) =>
            m.id === id
              ? { ...m, text: msg.text as string, isStreaming: false }
              : m
          )
        );
        currentAiMessageId.current = null;
        setIsSending(false);
        break;
      }

      case "error": {
        setIsSending(false);
        currentAiMessageId.current = null;
        break;
      }
    }
  }, []);

  useEffect(() => {
    connect();
    return () => {
      clearTimeout(reconnectTimer.current);
      wsRef.current?.close();
    };
  }, [connect]);

  const sendMessage = useCallback(
    (text: string) => {
      if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
      if (isSending) return;

      const userMsg: ChatMessage = {
        id: crypto.randomUUID(),
        text,
        sender: "user",
      };
      setMessages((prev) => [...prev, userMsg]);

      wsRef.current.send(
        JSON.stringify({ type: "send_message", text, sessionKey: "main" })
      );
    },
    [isSending]
  );

  return { isConnected, isDesktopOnline, messages, sendMessage, isSending };
}

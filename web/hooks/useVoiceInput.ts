import { useState, useRef, useCallback } from "react";

export function useVoiceInput(onTranscript: (text: string) => void) {
  const [recording, setRecording] = useState(false);
  const [transcribing, setTranscribing] = useState(false);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const recordingRef = useRef(false);
  const pendingStopRef = useRef(false);

  const startRecording = useCallback(async () => {
    if (recordingRef.current) return;
    pendingStopRef.current = false;

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });

      // If stop was requested while we were waiting for mic permission
      if (pendingStopRef.current) {
        stream.getTracks().forEach((t) => t.stop());
        return;
      }

      // Pick a supported mime type
      const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? "audio/webm;codecs=opus"
        : MediaRecorder.isTypeSupported("audio/webm")
          ? "audio/webm"
          : "audio/mp4";

      const mediaRecorder = new MediaRecorder(stream, { mimeType });
      mediaRecorderRef.current = mediaRecorder;
      chunksRef.current = [];

      mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      mediaRecorder.onstop = async () => {
        stream.getTracks().forEach((t) => t.stop());
        recordingRef.current = false;
        setRecording(false);
        const blob = new Blob(chunksRef.current, { type: mimeType });
        if (blob.size === 0) return;

        setTranscribing(true);
        try {
          const res = await fetch("/api/transcribe", {
            method: "POST",
            headers: { "Content-Type": mimeType },
            body: blob,
          });
          if (!res.ok) {
            console.error("Transcribe failed:", res.status);
            return;
          }
          const { transcript } = await res.json();
          if (transcript) onTranscript(transcript);
        } catch (err) {
          console.error("Transcribe error:", err);
        } finally {
          setTranscribing(false);
        }
      };

      mediaRecorder.start(100);
      recordingRef.current = true;
      setRecording(true);

      // If stop was requested during setup, stop immediately
      if (pendingStopRef.current) {
        mediaRecorder.stop();
      }
    } catch (err) {
      console.error("Mic access denied:", err);
      recordingRef.current = false;
      setRecording(false);
    }
  }, [onTranscript]);

  const stopRecording = useCallback(() => {
    pendingStopRef.current = true;
    if (mediaRecorderRef.current && mediaRecorderRef.current.state === "recording") {
      mediaRecorderRef.current.stop();
    }
  }, []);

  return { recording, transcribing, startRecording, stopRecording };
}

import { useState, useRef, useCallback } from "react";

export function useVoiceInput(onTranscript: (text: string) => void) {
  const [recording, setRecording] = useState(false);
  const [transcribing, setTranscribing] = useState(false);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);

  const startRecording = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });

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
      setRecording(true);
    } catch (err) {
      console.error("Mic access denied:", err);
    }
  }, [onTranscript]);

  const stopRecording = useCallback(() => {
    mediaRecorderRef.current?.stop();
    setRecording(false);
  }, []);

  const toggleRecording = useCallback(() => {
    if (recording) stopRecording();
    else startRecording();
  }, [recording, startRecording, stopRecording]);

  return { recording, transcribing, startRecording, stopRecording };
}

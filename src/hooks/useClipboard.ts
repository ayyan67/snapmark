import { useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useEditorStore } from "../stores/editorStore";

export function useClipboard() {
  const setBackgroundImage = useEditorStore((s) => s.setBackgroundImage);

  const pasteImageFromClipboard = useCallback(async () => {
    try {
      const base64: string = await invoke("read_clipboard_image");
      setBackgroundImage(`data:image/png;base64,${base64}`);
    } catch (e) {
      console.warn("No image in clipboard:", e);
    }
  }, [setBackgroundImage]);

  const copyToClipboard = useCallback(async (base64: string) => {
    try {
      await invoke("write_clipboard_image", { base64Png: base64 });
    } catch (e) {
      console.error("Failed to write to clipboard:", e);
    }
  }, []);

  return { pasteImageFromClipboard, copyToClipboard };
}

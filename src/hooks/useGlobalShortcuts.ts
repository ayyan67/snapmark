import { useEffect, useCallback, RefObject, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import Konva from "konva";
import { useEditorStore } from "../stores/editorStore";
import { useClipboard } from "./useClipboard";
import { exportStageToBase64 } from "../utils/exportCanvas";
import { ToolType } from "../types/shapes";

const TOOL_KEYS: Record<string, ToolType> = {
  "1": "select",
  "2": "pen",
  "3": "circle",
  "4": "rect",
  "5": "arrow",
  "6": "line",
  "7": "text",
};

export function useGlobalShortcuts(stageRef: RefObject<Konva.Stage | null>) {
  const { pasteImageFromClipboard, copyToClipboard } = useClipboard();
  const pasteHandlerRef = useRef<() => Promise<void>>(async () => {});
  const copyHandlerRef = useRef<() => Promise<void>>(async () => {});

  const handleCopy = useCallback(async () => {
    if (stageRef.current) {
      const base64 = exportStageToBase64(stageRef.current);
      await copyToClipboard(base64);
    }
  }, [stageRef, copyToClipboard]);

  useEffect(() => {
    pasteHandlerRef.current = pasteImageFromClipboard;
  }, [pasteImageFromClipboard]);

  useEffect(() => {
    copyHandlerRef.current = handleCopy;
  }, [handleCopy]);

  useEffect(() => {
    // Listen for paste-from-clipboard event from Tauri backend (global shortcut)
    const unlisten = listen("paste-from-clipboard", () => {
      void pasteHandlerRef.current();
    });

    const handleKeyDown = (e: KeyboardEvent) => {
      const meta = e.metaKey || e.ctrlKey;

      // Cmd+Z / Cmd+Shift+Z
      if (meta && e.key === "z") {
        e.preventDefault();
        if (e.shiftKey) {
          useEditorStore.getState().redo();
        } else {
          useEditorStore.getState().undo();
        }
        return;
      }

      // Cmd+C - copy
      if (meta && e.key === "c") {
        e.preventDefault();
        void copyHandlerRef.current();
        return;
      }

      // Cmd+V - paste
      if (meta && e.key === "v") {
        e.preventDefault();
        void pasteHandlerRef.current();
        return;
      }

      // Escape - hide window
      if (e.key === "Escape") {
        getCurrentWindow().hide();
        return;
      }

      // Backspace/Delete - delete selected shape
      if (e.key === "Backspace" || e.key === "Delete") {
        const selectedId = useEditorStore.getState().selectedShapeId;
        if (selectedId) {
          useEditorStore.getState().deleteShape(selectedId);
        }
        return;
      }

      // Number keys for tool switching (only when not typing in a text input)
      if (
        !meta &&
        !e.shiftKey &&
        TOOL_KEYS[e.key] &&
        !(e.target instanceof HTMLInputElement) &&
        !(e.target instanceof HTMLTextAreaElement)
      ) {
        useEditorStore.getState().setTool(TOOL_KEYS[e.key]);
        return;
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      void unlisten.then((fn) => fn());
    };
  }, []);

  return { handleCopy };
}

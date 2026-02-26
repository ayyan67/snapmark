import React from "react";
import { useShallow } from "zustand/react/shallow";
import { useEditorStore } from "../stores/editorStore";
import { ToolType } from "../types/shapes";
import ColorPicker from "./ColorPicker";
import StrokeWidth from "./StrokeWidth";

interface ToolDef {
  type: ToolType;
  label: string;
  shortcut: string;
  icon: React.ReactNode;
}

const TOOLS: ToolDef[] = [
  {
    type: "select",
    label: "Select",
    shortcut: "1",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 3l7.07 16.97 2.51-7.39 7.39-2.51L3 3z" />
      </svg>
    ),
  },
  {
    type: "pen",
    label: "Pen",
    shortcut: "2",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z" />
      </svg>
    ),
  },
  {
    type: "circle",
    label: "Circle",
    shortcut: "3",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <circle cx="12" cy="12" r="9" strokeWidth={2} />
      </svg>
    ),
  },
  {
    type: "rect",
    label: "Rectangle",
    shortcut: "4",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <rect x="3" y="5" width="18" height="14" rx="2" strokeWidth={2} />
      </svg>
    ),
  },
  {
    type: "arrow",
    label: "Arrow",
    shortcut: "5",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 19L19 5m0 0h-8m8 0v8" />
      </svg>
    ),
  },
  {
    type: "line",
    label: "Line",
    shortcut: "6",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <line x1="5" y1="19" x2="19" y2="5" strokeWidth={2} strokeLinecap="round" />
      </svg>
    ),
  },
  {
    type: "text",
    label: "Text",
    shortcut: "7",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M8 6v12m8-12v12" />
      </svg>
    ),
  },
];

interface ToolbarProps {
  onCopy: () => void;
}

export default function Toolbar({ onCopy }: ToolbarProps) {
  const { tool, setTool, undo, redo, clearShapes, canUndo, canRedo } =
    useEditorStore(
      useShallow((s) => ({
        tool: s.tool,
        setTool: s.setTool,
        undo: s.undo,
        redo: s.redo,
        clearShapes: s.clearShapes,
        canUndo: s.historyIndex > 0,
        canRedo: s.historyIndex < s.history.length - 1,
      })),
    );

  return (
    <div className="flex items-center h-12 bg-gray-800 px-3 gap-4 select-none" data-tauri-drag-region>
      {/* Tools */}
      <div className="flex items-center gap-0.5">
        {TOOLS.map((t) => (
          <button
            key={t.type}
            onClick={() => setTool(t.type)}
            className={`flex items-center justify-center w-8 h-8 rounded transition-colors ${
              tool === t.type
                ? "bg-blue-600 text-white"
                : "text-gray-300 hover:bg-gray-700 hover:text-white"
            }`}
            title={`${t.label} (${t.shortcut})`}
          >
            {t.icon}
          </button>
        ))}
      </div>

      {/* Divider */}
      <div className="w-px h-6 bg-gray-600" />

      {/* Colors */}
      <ColorPicker />

      {/* Divider */}
      <div className="w-px h-6 bg-gray-600" />

      {/* Stroke Width */}
      <StrokeWidth />

      {/* Divider */}
      <div className="w-px h-6 bg-gray-600" />

      {/* Undo/Redo */}
      <div className="flex items-center gap-0.5">
        <button
          onClick={undo}
          disabled={!canUndo}
          className={`flex items-center justify-center w-8 h-8 rounded transition-colors ${
            canUndo
              ? "text-gray-300 hover:bg-gray-700 hover:text-white"
              : "text-gray-600 cursor-not-allowed"
          }`}
          title="Undo (Cmd+Z)"
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 10h10a5 5 0 015 5v2M3 10l4-4M3 10l4 4" />
          </svg>
        </button>
        <button
          onClick={redo}
          disabled={!canRedo}
          className={`flex items-center justify-center w-8 h-8 rounded transition-colors ${
            canRedo
              ? "text-gray-300 hover:bg-gray-700 hover:text-white"
              : "text-gray-600 cursor-not-allowed"
          }`}
          title="Redo (Cmd+Shift+Z)"
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" className="w-5 h-5">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 10H11a5 5 0 00-5 5v2M21 10l-4-4M21 10l-4 4" />
          </svg>
        </button>
      </div>

      {/* Spacer */}
      <div className="flex-1" />

      {/* Actions */}
      <div className="flex items-center gap-2">
        <button
          onClick={clearShapes}
          className="px-3 py-1.5 text-sm text-gray-300 hover:text-white hover:bg-gray-700 rounded transition-colors"
          title="Clear all annotations"
        >
          Clear
        </button>
        <button
          onClick={onCopy}
          className="px-4 py-1.5 text-sm font-medium bg-blue-600 text-white rounded hover:bg-blue-500 transition-colors"
          title="Copy to clipboard (Cmd+C)"
        >
          Copy
        </button>
      </div>
    </div>
  );
}

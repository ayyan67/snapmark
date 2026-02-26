import { useRef } from "react";
import { useEditorStore } from "../stores/editorStore";

const PRESET_COLORS = [
  "#FF0000",
  "#2563EB",
  "#16A34A",
  "#EAB308",
  "#000000",
  "#FFFFFF",
];

export default function ColorPicker() {
  const color = useEditorStore((s) => s.color);
  const setColor = useEditorStore((s) => s.setColor);
  const inputRef = useRef<HTMLInputElement>(null);

  return (
    <div className="flex items-center gap-1.5">
      {PRESET_COLORS.map((c) => (
        <button
          key={c}
          onClick={() => setColor(c)}
          className="w-6 h-6 rounded-full border-2 transition-transform hover:scale-110"
          style={{
            backgroundColor: c,
            borderColor: color === c ? "#4A90D9" : c === "#FFFFFF" ? "#ccc" : c,
            boxShadow:
              color === c ? "0 0 0 2px #4A90D9" : "none",
          }}
          title={c}
        />
      ))}
      <div className="relative">
        <button
          onClick={() => inputRef.current?.click()}
          className="w-6 h-6 rounded-full border-2 border-gray-500 overflow-hidden"
          style={{
            background:
              "conic-gradient(red, yellow, lime, aqua, blue, magenta, red)",
          }}
          title="Custom color"
        />
        <input
          ref={inputRef}
          type="color"
          value={color}
          onChange={(e) => setColor(e.target.value)}
          className="absolute opacity-0 w-0 h-0"
        />
      </div>
    </div>
  );
}

import { useEditorStore } from "../stores/editorStore";

const WIDTHS = [
  { value: 2, label: "Thin" },
  { value: 4, label: "Medium" },
  { value: 8, label: "Thick" },
];

export default function StrokeWidth() {
  const strokeWidth = useEditorStore((s) => s.strokeWidth);
  const setStrokeWidth = useEditorStore((s) => s.setStrokeWidth);

  return (
    <div className="flex items-center gap-1">
      {WIDTHS.map((w) => (
        <button
          key={w.value}
          onClick={() => setStrokeWidth(w.value)}
          className={`flex items-center justify-center w-8 h-8 rounded transition-colors ${
            strokeWidth === w.value
              ? "bg-gray-600"
              : "hover:bg-gray-700"
          }`}
          title={w.label}
        >
          <div
            className="rounded-full bg-white"
            style={{
              width: `${w.value * 2 + 4}px`,
              height: `${w.value * 2 + 4}px`,
            }}
          />
        </button>
      ))}
    </div>
  );
}

export default function EmptyState() {
  return (
    <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none z-10">
      <div className="text-gray-400 text-center">
        <svg
          className="w-16 h-16 mx-auto mb-4 text-gray-300"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={1.5}
            d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
          />
        </svg>
        <p className="text-lg font-medium mb-2">No image loaded</p>
        <p className="text-sm">
          Press{" "}
          <kbd className="px-2 py-1 bg-gray-200 text-gray-600 rounded text-xs font-mono">
            Cmd+V
          </kbd>{" "}
          to paste or{" "}
          <kbd className="px-2 py-1 bg-gray-200 text-gray-600 rounded text-xs font-mono">
            Cmd+Shift+A
          </kbd>{" "}
          from anywhere
        </p>
      </div>
    </div>
  );
}

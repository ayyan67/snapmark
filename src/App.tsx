import { useRef, useState, useEffect, useCallback } from "react";
import Konva from "konva";
import Canvas from "./components/Canvas";
import Toolbar from "./components/Toolbar";
import { useGlobalShortcuts } from "./hooks/useGlobalShortcuts";

export default function App() {
  const stageRef = useRef<Konva.Stage>(null);
  const { handleCopy } = useGlobalShortcuts(stageRef);
  const [dimensions, setDimensions] = useState({
    width: window.innerWidth,
    height: window.innerHeight - 48, // minus toolbar height
  });

  const handleResize = useCallback(() => {
    setDimensions({
      width: window.innerWidth,
      height: window.innerHeight - 48,
    });
  }, []);

  useEffect(() => {
    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, [handleResize]);

  return (
    <div className="flex flex-col h-screen w-screen bg-gray-900">
      <Toolbar onCopy={handleCopy} />
      <div className="flex-1 overflow-hidden">
        <Canvas
          ref={stageRef}
          width={dimensions.width}
          height={dimensions.height}
        />
      </div>
    </div>
  );
}

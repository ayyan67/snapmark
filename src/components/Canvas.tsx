import {
  useRef,
  useState,
  useEffect,
  useCallback,
  forwardRef,
  useImperativeHandle,
  useMemo,
} from "react";
import {
  Stage,
  Layer,
  Line,
  Ellipse,
  Rect,
  Arrow,
  Text,
  Image as KonvaImage,
  Transformer,
} from "react-konva";
import Konva from "konva";
import { useShallow } from "zustand/react/shallow";
import { useEditorStore } from "../stores/editorStore";
import { Shape, TextShape } from "../types/shapes";
import EmptyState from "./EmptyState";

const FLOAT_EPSILON = 0.001;

function generateId(): string {
  return `shape_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

function hasValueChanged(previous: number, next: number): boolean {
  return Math.abs(previous - next) > FLOAT_EPSILON;
}

interface CanvasProps {
  width: number;
  height: number;
}

const Canvas = forwardRef<Konva.Stage, CanvasProps>(({ width, height }, ref) => {
  const stageRef = useRef<Konva.Stage>(null);
  const transformerRef = useRef<Konva.Transformer>(null);
  const isDrawing = useRef(false);
  const drawingShape = useRef<Shape | null>(null);

  const {
    tool,
    color,
    strokeWidth,
    shapes,
    backgroundImage,
    selectedShapeId,
    addShape,
    updateShape,
    setSelectedShapeId,
    pushHistory,
  } = useEditorStore(
    useShallow((s) => ({
      tool: s.tool,
      color: s.color,
      strokeWidth: s.strokeWidth,
      shapes: s.shapes,
      backgroundImage: s.backgroundImage,
      selectedShapeId: s.selectedShapeId,
      addShape: s.addShape,
      updateShape: s.updateShape,
      setSelectedShapeId: s.setSelectedShapeId,
      pushHistory: s.pushHistory,
    })),
  );

  const [bgImage, setBgImage] = useState<HTMLImageElement | null>(null);
  const [editingTextId, setEditingTextId] = useState<string | null>(null);
  const [tempShape, setTempShape] = useState<Shape | null>(null);

  useImperativeHandle(ref, () => stageRef.current!, []);

  useEffect(() => {
    if (backgroundImage) {
      const img = new window.Image();
      img.onload = () => setBgImage(img);
      img.src = backgroundImage;
      return;
    }

    setBgImage(null);
  }, [backgroundImage]);

  useEffect(() => {
    if (!transformerRef.current || !stageRef.current) return;

    if (selectedShapeId && tool === "select") {
      const node = stageRef.current.findOne(`#${selectedShapeId}`);
      if (node) {
        transformerRef.current.nodes([node]);
        transformerRef.current.getLayer()?.batchDraw();
        return;
      }
    }

    transformerRef.current.nodes([]);
    transformerRef.current.getLayer()?.batchDraw();
  }, [selectedShapeId, tool, shapes]);

  const cursorStyle = useMemo(() => {
    switch (tool) {
      case "select":
        return "default";
      case "text":
        return "text";
      default:
        return "crosshair";
    }
  }, [tool]);

  const getPointerPos = useCallback(() => {
    const stage = stageRef.current;
    if (!stage) return { x: 0, y: 0 };
    const pos = stage.getPointerPosition();
    return pos || { x: 0, y: 0 };
  }, []);

  const handlePointerDown = useCallback(
    (e: Konva.KonvaEventObject<MouseEvent | TouchEvent>) => {
      if (tool === "select") {
        if (e.target === e.target.getStage()) {
          setSelectedShapeId(null);
        }
        return;
      }

      if (tool === "text") {
        const pos = getPointerPos();
        const id = generateId();
        const textShape: TextShape = {
          id,
          type: "text",
          x: pos.x,
          y: pos.y,
          text: "Text",
          fontSize: Math.max(16, strokeWidth * 6),
          color,
          strokeWidth,
        };
        addShape(textShape);
        setEditingTextId(id);
        return;
      }

      isDrawing.current = true;
      const pos = getPointerPos();
      const id = generateId();

      let shape: Shape;
      switch (tool) {
        case "pen":
          shape = {
            id,
            type: "freehand",
            points: [pos.x, pos.y],
            color,
            strokeWidth,
          };
          break;
        case "circle":
          shape = {
            id,
            type: "circle",
            x: pos.x,
            y: pos.y,
            radiusX: 0,
            radiusY: 0,
            color,
            strokeWidth,
          };
          break;
        case "rect":
          shape = {
            id,
            type: "rect",
            x: pos.x,
            y: pos.y,
            width: 0,
            height: 0,
            color,
            strokeWidth,
          };
          break;
        case "arrow":
          shape = {
            id,
            type: "arrow",
            points: [pos.x, pos.y, pos.x, pos.y],
            color,
            strokeWidth,
          };
          break;
        case "line":
          shape = {
            id,
            type: "line",
            points: [pos.x, pos.y, pos.x, pos.y],
            color,
            strokeWidth,
          };
          break;
        default:
          return;
      }

      drawingShape.current = shape;
      setTempShape(shape);
    },
    [tool, color, strokeWidth, addShape, getPointerPos, setSelectedShapeId],
  );

  const handlePointerMove = useCallback(
    (e: Konva.KonvaEventObject<MouseEvent | TouchEvent>) => {
      if (!isDrawing.current || !drawingShape.current) return;

      const pos = getPointerPos();
      const shape = drawingShape.current;
      const shiftKey = e.evt instanceof MouseEvent ? e.evt.shiftKey : false;

      let updated: Shape;
      switch (shape.type) {
        case "freehand": {
          const lastX = shape.points[shape.points.length - 2];
          const lastY = shape.points[shape.points.length - 1];
          if (lastX === pos.x && lastY === pos.y) return;

          updated = {
            ...shape,
            points: [...shape.points, pos.x, pos.y],
          };
          break;
        }
        case "circle": {
          const dx = pos.x - shape.x;
          const dy = pos.y - shape.y;
          if (shiftKey) {
            const r = Math.sqrt(dx * dx + dy * dy);
            updated = { ...shape, radiusX: r, radiusY: r };
          } else {
            updated = {
              ...shape,
              radiusX: Math.abs(dx),
              radiusY: Math.abs(dy),
            };
          }
          break;
        }
        case "rect": {
          let w = pos.x - shape.x;
          let h = pos.y - shape.y;
          if (shiftKey) {
            const size = Math.max(Math.abs(w), Math.abs(h));
            w = Math.sign(w) * size;
            h = Math.sign(h) * size;
          }
          updated = { ...shape, width: w, height: h };
          break;
        }
        case "arrow":
        case "line": {
          const previousPoints = shape.points;
          if (previousPoints[2] === pos.x && previousPoints[3] === pos.y) {
            return;
          }

          updated = {
            ...shape,
            points: [previousPoints[0], previousPoints[1], pos.x, pos.y],
          };
          break;
        }
        default:
          return;
      }

      drawingShape.current = updated;
      setTempShape(updated);
    },
    [getPointerPos],
  );

  const finishDrawing = useCallback(() => {
    if (!isDrawing.current || !drawingShape.current) return;

    isDrawing.current = false;
    const shape = drawingShape.current;

    let hasSize = true;
    switch (shape.type) {
      case "freehand":
        hasSize = shape.points.length > 4;
        break;
      case "circle":
        hasSize = shape.radiusX > 2 || shape.radiusY > 2;
        break;
      case "rect":
        hasSize = Math.abs(shape.width) > 2 || Math.abs(shape.height) > 2;
        break;
      case "arrow":
      case "line": {
        const dx = shape.points[2] - shape.points[0];
        const dy = shape.points[3] - shape.points[1];
        hasSize = Math.sqrt(dx * dx + dy * dy) > 2;
        break;
      }
    }

    if (hasSize) {
      addShape(shape);
    }

    drawingShape.current = null;
    setTempShape(null);
  }, [addShape]);

  const handleMouseDown = useCallback(
    (e: Konva.KonvaEventObject<MouseEvent>) => {
      handlePointerDown(e);
    },
    [handlePointerDown],
  );

  const handleTouchStart = useCallback(
    (e: Konva.KonvaEventObject<TouchEvent>) => {
      handlePointerDown(e);
    },
    [handlePointerDown],
  );

  const handleMouseMove = useCallback(
    (e: Konva.KonvaEventObject<MouseEvent>) => {
      handlePointerMove(e);
    },
    [handlePointerMove],
  );

  const handleTouchMove = useCallback(
    (e: Konva.KonvaEventObject<TouchEvent>) => {
      handlePointerMove(e);
    },
    [handlePointerMove],
  );

  const handleMouseUp = useCallback(
    (_e: Konva.KonvaEventObject<MouseEvent>) => {
      finishDrawing();
    },
    [finishDrawing],
  );

  const handleTouchEnd = useCallback(
    (_e: Konva.KonvaEventObject<TouchEvent>) => {
      finishDrawing();
    },
    [finishDrawing],
  );

  const handleShapeClick = useCallback(
    (shapeId: string) => {
      if (tool === "select") {
        setSelectedShapeId(shapeId);
      }
    },
    [tool, setSelectedShapeId],
  );

  const handleTextDblClick = useCallback((shapeId: string) => {
    setEditingTextId(shapeId);
  }, []);

  const handleTransformEnd = useCallback(
    (e: Konva.KonvaEventObject<Event>) => {
      const node = e.target;
      const id = node.id();
      const shape = shapes.find((s) => s.id === id);
      if (!shape) return;

      if (shape.type === "rect") {
        const nextX = node.x();
        const nextY = node.y();
        const nextWidth = node.width() * node.scaleX();
        const nextHeight = node.height() * node.scaleY();

        node.scaleX(1);
        node.scaleY(1);

        const hasChanged =
          hasValueChanged(shape.x, nextX) ||
          hasValueChanged(shape.y, nextY) ||
          hasValueChanged(shape.width, nextWidth) ||
          hasValueChanged(shape.height, nextHeight);

        if (!hasChanged) return;

        updateShape(id, {
          x: nextX,
          y: nextY,
          width: nextWidth,
          height: nextHeight,
        });
        pushHistory();
        return;
      }

      if (shape.type === "circle") {
        const nextX = node.x();
        const nextY = node.y();
        const nextRadiusX = shape.radiusX * node.scaleX();
        const nextRadiusY = shape.radiusY * node.scaleY();

        node.scaleX(1);
        node.scaleY(1);

        const hasChanged =
          hasValueChanged(shape.x, nextX) ||
          hasValueChanged(shape.y, nextY) ||
          hasValueChanged(shape.radiusX, nextRadiusX) ||
          hasValueChanged(shape.radiusY, nextRadiusY);

        if (!hasChanged) return;

        updateShape(id, {
          x: nextX,
          y: nextY,
          radiusX: nextRadiusX,
          radiusY: nextRadiusY,
        });
        pushHistory();
      }
    },
    [shapes, updateShape, pushHistory],
  );

  const handleDragEnd = useCallback(
    (e: Konva.KonvaEventObject<DragEvent>) => {
      const node = e.target;
      const id = node.id();
      const shape = shapes.find((s) => s.id === id);
      if (!shape) return;

      if (shape.type === "text" || shape.type === "rect" || shape.type === "circle") {
        const nextX = node.x();
        const nextY = node.y();
        if (!hasValueChanged(shape.x, nextX) && !hasValueChanged(shape.y, nextY)) {
          return;
        }

        updateShape(id, { x: nextX, y: nextY });
        pushHistory();
      }
    },
    [shapes, updateShape, pushHistory],
  );

  const renderShape = (shape: Shape) => {
    const commonProps = {
      id: shape.id,
      key: shape.id,
      onClick: () => handleShapeClick(shape.id),
      onTap: () => handleShapeClick(shape.id),
      draggable: tool === "select",
      onDragEnd: handleDragEnd,
      onTransformEnd: handleTransformEnd,
      shadowColor: "rgba(0,0,0,0.3)",
      shadowBlur: 4,
      shadowOffset: { x: 1, y: 1 },
      shadowOpacity: 0.3,
    };

    switch (shape.type) {
      case "freehand":
        return (
          <Line
            {...commonProps}
            points={shape.points}
            stroke={shape.color}
            strokeWidth={shape.strokeWidth}
            lineCap="round"
            lineJoin="round"
            tension={0.5}
            globalCompositeOperation="source-over"
          />
        );
      case "circle":
        return (
          <Ellipse
            {...commonProps}
            x={shape.x}
            y={shape.y}
            radiusX={shape.radiusX}
            radiusY={shape.radiusY}
            stroke={shape.color}
            strokeWidth={shape.strokeWidth}
            fill="transparent"
          />
        );
      case "rect":
        return (
          <Rect
            {...commonProps}
            x={shape.x}
            y={shape.y}
            width={shape.width}
            height={shape.height}
            stroke={shape.color}
            strokeWidth={shape.strokeWidth}
            fill="transparent"
          />
        );
      case "arrow":
        return (
          <Arrow
            {...commonProps}
            points={shape.points}
            stroke={shape.color}
            strokeWidth={shape.strokeWidth}
            fill={shape.color}
            pointerLength={shape.strokeWidth * 3}
            pointerWidth={shape.strokeWidth * 3}
            lineCap="round"
            lineJoin="round"
          />
        );
      case "line":
        return (
          <Line
            {...commonProps}
            points={shape.points}
            stroke={shape.color}
            strokeWidth={shape.strokeWidth}
            lineCap="round"
            lineJoin="round"
          />
        );
      case "text":
        return (
          <Text
            {...commonProps}
            x={shape.x}
            y={shape.y}
            text={shape.text}
            fontSize={shape.fontSize}
            fill={shape.color}
            onDblClick={() => handleTextDblClick(shape.id)}
            onDblTap={() => handleTextDblClick(shape.id)}
          />
        );
      default:
        return null;
    }
  };

  useEffect(() => {
    if (!editingTextId || !stageRef.current) return;
    const editingId = editingTextId;

    const shape = shapes.find(
      (candidate): candidate is TextShape =>
        candidate.id === editingId && candidate.type === "text",
    );
    if (!shape) return;
    const editingShape = shape;

    const textNode = stageRef.current.findOne(`#${editingId}`);
    if (!textNode) return;

    const stageBox = stageRef.current.container().getBoundingClientRect();
    const absPos = textNode.getAbsolutePosition();

    const textarea = document.createElement("textarea");
    let isRemoved = false;

    function cleanupTextarea() {
      if (isRemoved) return;
      isRemoved = true;
      textarea.removeEventListener("blur", handleBlur);
      textarea.removeEventListener("keydown", handleKeyDown);
      if (textarea.parentNode) {
        textarea.parentNode.removeChild(textarea);
      }
    }

    function finishEditing() {
      if (isRemoved) return;

      const newText = textarea.value;
      if (newText.trim() && newText !== editingShape.text) {
        updateShape(editingId, { text: newText });
        pushHistory();
      }

      cleanupTextarea();
      setEditingTextId(null);
    }

    function cancelEditing() {
      cleanupTextarea();
      setEditingTextId(null);
    }

    function handleBlur() {
      finishEditing();
    }

    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        finishEditing();
      }

      if (e.key === "Escape") {
        cancelEditing();
      }
    }

    document.body.appendChild(textarea);

    textarea.value = shape.text;
    textarea.style.position = "absolute";
    textarea.style.top = `${stageBox.top + absPos.y}px`;
    textarea.style.left = `${stageBox.left + absPos.x}px`;
    textarea.style.fontSize = `${shape.fontSize}px`;
    textarea.style.color = shape.color;
    textarea.style.border = "2px solid #4A90D9";
    textarea.style.padding = "4px";
    textarea.style.margin = "0";
    textarea.style.overflow = "hidden";
    textarea.style.background = "rgba(255,255,255,0.9)";
    textarea.style.outline = "none";
    textarea.style.resize = "none";
    textarea.style.lineHeight = "1.2";
    textarea.style.fontFamily = "-apple-system, BlinkMacSystemFont, sans-serif";
    textarea.style.borderRadius = "4px";
    textarea.style.minWidth = "100px";
    textarea.style.minHeight = "30px";
    textarea.style.zIndex = "1000";

    textarea.addEventListener("blur", handleBlur);
    textarea.addEventListener("keydown", handleKeyDown);
    textarea.focus();

    return () => {
      cleanupTextarea();
    };
  }, [editingTextId, shapes, updateShape, pushHistory]);

  const bgDims = useMemo(() => {
    if (!bgImage) {
      return { x: 0, y: 0, w: width, h: height };
    }

    const scale = Math.min(width / bgImage.width, height / bgImage.height);
    const w = bgImage.width * scale;
    const h = bgImage.height * scale;

    return {
      x: (width - w) / 2,
      y: (height - h) / 2,
      w,
      h,
    };
  }, [bgImage, width, height]);

  return (
    <div
      className={`relative ${!bgImage ? "checkerboard" : ""}`}
      style={{ width, height, cursor: cursorStyle }}
    >
      {!bgImage && !shapes.length && <EmptyState />}
      <Stage
        ref={stageRef}
        width={width}
        height={height}
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={handleMouseUp}
        onTouchStart={handleTouchStart}
        onTouchMove={handleTouchMove}
        onTouchEnd={handleTouchEnd}
      >
        <Layer>
          {bgImage && (
            <KonvaImage
              image={bgImage}
              x={bgDims.x}
              y={bgDims.y}
              width={bgDims.w}
              height={bgDims.h}
            />
          )}
        </Layer>

        <Layer>
          {shapes.map(renderShape)}
          {tempShape && renderShape(tempShape)}
          {tool === "select" && (
            <Transformer
              ref={transformerRef}
              boundBoxFunc={(oldBox, newBox) => {
                if (newBox.width < 5 || newBox.height < 5) return oldBox;
                return newBox;
              }}
            />
          )}
        </Layer>
      </Stage>
    </div>
  );
});

Canvas.displayName = "Canvas";

export default Canvas;

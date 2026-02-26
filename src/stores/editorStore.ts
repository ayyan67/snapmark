import { create } from "zustand";
import {
  Shape,
  ToolType,
  FreehandShape,
  CircleShape,
  RectShape,
  ArrowShape,
  LineShape,
  TextShape,
} from "../types/shapes";

const HISTORY_LIMIT = 100;

function areNumberArraysEqual(a: number[], b: number[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function areShapesEqual(a: Shape, b: Shape): boolean {
  if (a.type !== b.type || a.id !== b.id || a.color !== b.color || a.strokeWidth !== b.strokeWidth) {
    return false;
  }

  switch (a.type) {
    case "freehand":
      return areNumberArraysEqual(a.points, (b as FreehandShape).points);
    case "circle":
      return (
        a.x === (b as CircleShape).x &&
        a.y === (b as CircleShape).y &&
        a.radiusX === (b as CircleShape).radiusX &&
        a.radiusY === (b as CircleShape).radiusY
      );
    case "rect":
      return (
        a.x === (b as RectShape).x &&
        a.y === (b as RectShape).y &&
        a.width === (b as RectShape).width &&
        a.height === (b as RectShape).height
      );
    case "arrow":
      return areNumberArraysEqual(a.points, (b as ArrowShape).points);
    case "line":
      return areNumberArraysEqual(a.points, (b as LineShape).points);
    case "text":
      return (
        a.x === (b as TextShape).x &&
        a.y === (b as TextShape).y &&
        a.text === (b as TextShape).text &&
        a.fontSize === (b as TextShape).fontSize
      );
    default:
      return false;
  }
}

function areShapeSnapshotsEqual(a: Shape[], b: Shape[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (!areShapesEqual(a[i], b[i])) return false;
  }
  return true;
}

function appendHistorySnapshot(
  history: Shape[][],
  historyIndex: number,
  snapshot: Shape[],
): { history: Shape[][]; historyIndex: number; didAppend: boolean } {
  const truncated = history.slice(0, historyIndex + 1);
  const latest = truncated[truncated.length - 1];

  if (latest && areShapeSnapshotsEqual(latest, snapshot)) {
    return {
      history: truncated,
      historyIndex: truncated.length - 1,
      didAppend: false,
    };
  }

  const nextHistory = [...truncated, snapshot];
  if (nextHistory.length <= HISTORY_LIMIT) {
    return {
      history: nextHistory,
      historyIndex: nextHistory.length - 1,
      didAppend: true,
    };
  }

  const trimmedHistory = nextHistory.slice(nextHistory.length - HISTORY_LIMIT);
  return {
    history: trimmedHistory,
    historyIndex: trimmedHistory.length - 1,
    didAppend: true,
  };
}

interface EditorState {
  tool: ToolType;
  color: string;
  strokeWidth: number;
  shapes: Shape[];
  backgroundImage: string | null;
  selectedShapeId: string | null;

  // History
  history: Shape[][];
  historyIndex: number;

  // Actions
  setTool: (tool: ToolType) => void;
  setColor: (color: string) => void;
  setStrokeWidth: (width: number) => void;
  setBackgroundImage: (image: string | null) => void;
  setSelectedShapeId: (id: string | null) => void;
  addShape: (shape: Shape) => void;
  updateShape: (id: string, updates: Partial<Shape>) => void;
  deleteShape: (id: string) => void;
  clearShapes: () => void;
  undo: () => void;
  redo: () => void;
  canUndo: () => boolean;
  canRedo: () => boolean;
  pushHistory: () => void;
}

export const useEditorStore = create<EditorState>((set, get) => ({
  tool: "pen",
  color: "#FF0000",
  strokeWidth: 4,
  shapes: [],
  backgroundImage: null,
  selectedShapeId: null,

  history: [[]],
  historyIndex: 0,

  setTool: (tool) => set({ tool, selectedShapeId: null }),
  setColor: (color) => set({ color }),
  setStrokeWidth: (strokeWidth) => set({ strokeWidth }),
  setBackgroundImage: (backgroundImage) => set({ backgroundImage }),
  setSelectedShapeId: (selectedShapeId) => set({ selectedShapeId }),

  addShape: (shape) => {
    const state = get();
    const newShapes = [...state.shapes, shape];
    const { history, historyIndex } = appendHistorySnapshot(
      state.history,
      state.historyIndex,
      newShapes,
    );
    set({
      shapes: newShapes,
      history,
      historyIndex,
    });
  },

  updateShape: (id, updates) => {
    const state = get();
    const newShapes = state.shapes.map((s) =>
      s.id === id ? ({ ...s, ...updates } as Shape) : s,
    );
    set({ shapes: newShapes });
  },

  deleteShape: (id) => {
    const state = get();
    const newShapes = state.shapes.filter((s) => s.id !== id);
    const { history, historyIndex } = appendHistorySnapshot(
      state.history,
      state.historyIndex,
      newShapes,
    );
    set({
      shapes: newShapes,
      history,
      historyIndex,
      selectedShapeId: null,
    });
  },

  clearShapes: () => {
    const state = get();
    const { history, historyIndex } = appendHistorySnapshot(
      state.history,
      state.historyIndex,
      [],
    );
    set({
      shapes: [],
      history,
      historyIndex,
      selectedShapeId: null,
    });
  },

  pushHistory: () => {
    const state = get();
    const snapshot = [...state.shapes];
    const { history, historyIndex, didAppend } = appendHistorySnapshot(
      state.history,
      state.historyIndex,
      snapshot,
    );
    if (!didAppend) return;
    set({
      history,
      historyIndex,
    });
  },

  undo: () => {
    const state = get();
    if (state.historyIndex > 0) {
      const newIndex = state.historyIndex - 1;
      set({
        shapes: [...state.history[newIndex]],
        historyIndex: newIndex,
        selectedShapeId: null,
      });
    }
  },

  redo: () => {
    const state = get();
    if (state.historyIndex < state.history.length - 1) {
      const newIndex = state.historyIndex + 1;
      set({
        shapes: [...state.history[newIndex]],
        historyIndex: newIndex,
        selectedShapeId: null,
      });
    }
  },

  canUndo: () => get().historyIndex > 0,
  canRedo: () => get().historyIndex < get().history.length - 1,
}));

export type ToolType =
  | "select"
  | "pen"
  | "circle"
  | "rect"
  | "arrow"
  | "line"
  | "text";

interface BaseShape {
  id: string;
  color: string;
  strokeWidth: number;
}

export interface FreehandShape extends BaseShape {
  type: "freehand";
  points: number[];
}

export interface CircleShape extends BaseShape {
  type: "circle";
  x: number;
  y: number;
  radiusX: number;
  radiusY: number;
}

export interface RectShape extends BaseShape {
  type: "rect";
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ArrowShape extends BaseShape {
  type: "arrow";
  points: [number, number, number, number];
}

export interface LineShape extends BaseShape {
  type: "line";
  points: [number, number, number, number];
}

export interface TextShape extends BaseShape {
  type: "text";
  x: number;
  y: number;
  text: string;
  fontSize: number;
}

export type Shape =
  | FreehandShape
  | CircleShape
  | RectShape
  | ArrowShape
  | LineShape
  | TextShape;

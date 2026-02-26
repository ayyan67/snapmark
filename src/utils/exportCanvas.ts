import Konva from "konva";

export function exportStageToBase64(stage: Konva.Stage): string {
  const dataUrl = stage.toDataURL({ pixelRatio: 2 });
  // Remove the data:image/png;base64, prefix
  return dataUrl.replace(/^data:image\/png;base64,/, "");
}

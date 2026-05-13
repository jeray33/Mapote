declare module "@dragdroptouch/drag-drop-touch" {
  export interface DragDropTouchOptions {
    allowDragScroll?: boolean;
    contextMenuDelayMS?: number;
    dragImageOpacity?: number;
    dragScrollPercentage?: number;
    dragScrollSpeed?: number;
    dragThresholdPixels?: number;
    forceListen?: boolean;
    isPressHoldMode?: boolean;
    pressHoldDelayMS?: number;
    pressHoldMargin?: number;
    pressHoldThresholdPixels?: number;
  }

  export function enableDragDropTouch(
    dragRoot?: Document | Element,
    dropRoot?: Document | Element,
    options?: DragDropTouchOptions
  ): void;
}

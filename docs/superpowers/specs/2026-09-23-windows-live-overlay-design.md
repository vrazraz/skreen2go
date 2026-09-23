# Windows live selection overlay

## Goal

Make the Windows capture flow resemble the macOS flow shown in `Marketing/AppStore/ru/01-screenshots.jpg` and implemented in `Sources/Skreen2GoCore/Capture.swift`. After a drag or window click, keep the selection on screen with a 60% dimmed outside area, a white frame with eight square handles, and a compact light action bar adjacent to the frame.

## Interaction

- A new drag creates a live selection. Clicking a visible window chooses its bounds. A click outside a live selection starts a new selection.
- Drag inside the frame to move it; drag a handle to resize it. The action bar hides during either gesture and reappears afterward. The frame and bar remain visible until an action or Escape.
- Screenshot mode offers cancel, arrow, rectangle, text, color palette, undo, redo, settings, copy, save, and save as. Annotation tools draw within the selection. Enter or a double click opens the full editor with existing annotations.
- Recording mode offers cancel, settings, system audio, microphone, and a red record button. The record button starts the existing countdown and recording flow.
- The bar fits within the virtual desktop: prefer below the selection, then above, then right or left, finally inside. It keeps its natural width even for small selections.

## Data and rendering

Keep the frozen desktop screenshot captured before the overlay opens. Draw the dim layer over it, then show the untouched screenshot only in the selected rectangle. Store annotations in selection-local physical pixels, so moving the frame moves them without changing their coordinates. Render exported images from the cropped bitmap and those annotations at source resolution. WPF converts physical screen coordinates only when drawing the overlay.

## Verification

Test frame movement, resizing, placement and annotation coordinates in the core project. Build the WPF app, run the core suite, then inspect a real Windows overlay after a drag and verify that copy/save and recording still work. Mixed-DPI monitors remain a manual verification case.

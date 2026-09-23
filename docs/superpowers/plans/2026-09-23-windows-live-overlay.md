# Windows live overlay implementation

1. Add core geometry for moving and resizing a live selection and placing the floating bar. Write focused tests first.
2. Keep the selection in `CaptureWindow` after mouse release. Draw the dimmed outside area, white border, eight handles, size badge and nearby action bar.
3. Support direct arrow, rectangle and text annotations with undo/redo and a small color palette. Export annotations from the same selection-local model used by the editor.
4. Wire screenshot actions and recording controls to the existing `App` flows. Keep settings reachable while the overlay is open.
5. Build and test; exercise the overlay on Windows, update documentation, publish a new self-contained archive, and restart the app.

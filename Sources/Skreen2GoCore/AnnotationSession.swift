import Foundation

/// Shared annotation state and snapshot history used by the live capture overlay and the
/// full editor. Keeping the history here prevents the two editing surfaces from drifting
/// apart as new annotation operations are added.
final class AnnotationSession {
    var annotations: [Annotation] = []

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var pendingUndoSnapshot: [Annotation]?

    private let undoLimit: Int

    init(undoLimit: Int = 50) {
        self.undoLimit = max(1, undoLimit)
    }

    var undoDepth: Int { undoStack.count }
    var redoDepth: Int { redoStack.count }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    func beginUndoGroup() {
        pendingUndoSnapshot = annotations
    }

    func commitUndoGroup() {
        guard let snapshot = pendingUndoSnapshot else { return }
        pendingUndoSnapshot = nil
        pushUndo(snapshot)
    }

    func cancelUndoGroup() {
        pendingUndoSnapshot = nil
    }

    func recordUndo() {
        pushUndo(annotations)
    }

    private func pushUndo(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
}

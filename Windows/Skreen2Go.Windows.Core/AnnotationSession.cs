namespace Skreen2Go.Windows.Core;

public sealed class AnnotationSession
{
    private readonly List<Annotation> annotations = [];
    private readonly Stack<Annotation[]> undo = new();
    private readonly Stack<Annotation[]> redo = new();
    private readonly int undoLimit;

    public AnnotationSession(int undoLimit = 50) => this.undoLimit = Math.Max(1, undoLimit);

    public IReadOnlyList<Annotation> Annotations => annotations;
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;

    public bool Add(Annotation annotation)
    {
        if (!AnnotationGeometry.IsMeaningful(annotation)) return false;
        RecordUndo();
        annotations.Add(annotation);
        return true;
    }

    public void Undo()
    {
        if (!undo.TryPop(out var previous)) return;
        redo.Push([.. annotations]);
        Restore(previous);
    }

    public void Redo()
    {
        if (!redo.TryPop(out var next)) return;
        undo.Push([.. annotations]);
        Restore(next);
    }

    private void RecordUndo()
    {
        if (undo.Count >= undoLimit)
        {
            var oldestFirst = undo.Reverse().Skip(1).ToArray();
            undo.Clear();
            foreach (var snapshot in oldestFirst) undo.Push(snapshot);
        }
        undo.Push([.. annotations]);
        redo.Clear();
    }

    private void Restore(Annotation[] snapshot)
    {
        annotations.Clear();
        annotations.AddRange(snapshot);
    }
}

# Windows Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a runnable Windows tray app that selects a screen region, annotates it, and copies or saves a full-resolution screenshot.

**Architecture:** A dependency-free C# core owns selection, annotations, settings and file names. A .NET 10 WPF executable owns Windows integration and the visible workflow. Selection and crop coordinates are physical desktop pixels.

**Tech Stack:** .NET 10, C#, WPF, WinForms tray icon, Win32 P/Invoke, System.Drawing for bitmap capture and export.

## Global Constraints

- Keep the Swift/macOS source untouched.
- Run on Windows 11 and use PerMonitorV2 DPI awareness.
- Default shortcut is Ctrl+Shift+S; output folder is Downloads.
- Preserve source pixels during crop and annotation export.
- The new Windows project must build and its core tests must pass before completion.

---

### Task 1: Core selection and output rules

**Files:**
- Create: `Windows/Skreen2Go.Windows.Core/Skreen2Go.Windows.Core.csproj`
- Create: `Windows/Skreen2Go.Windows.Core/SelectionGeometry.cs`
- Create: `Windows/Skreen2Go.Windows.Core/OutputNaming.cs`
- Create: `Windows/Skreen2Go.Windows.Core.Tests/Skreen2Go.Windows.Core.Tests.csproj`
- Create: `Windows/Skreen2Go.Windows.Core.Tests/Program.cs`

**Interfaces:** `SelectionGeometry.Normalize(PointI, PointI): RectangleI`, `SelectionGeometry.Clamp(RectangleI, RectangleI): RectangleI`, `OutputNaming.NextPath(string, string, DateTimeOffset, Func<string,bool>): string`.

- [ ] Write tests that a reversed drag normalizes, a selection outside the virtual desktop clamps, and two saves in one second receive distinct names. Use literal rectangles and paths.
- [ ] Run `dotnet run --project Windows/Skreen2Go.Windows.Core.Tests` and confirm the tests fail because the behavior is missing.
- [ ] Implement the minimum core types and rules.
- [ ] Run the same command and confirm all core tests pass. Commit the core and tests.

### Task 2: Annotation model and renderable history

**Files:**
- Create: `Windows/Skreen2Go.Windows.Core/Annotation.cs`
- Create: `Windows/Skreen2Go.Windows.Core/AnnotationSession.cs`
- Modify: `Windows/Skreen2Go.Windows.Core.Tests/Program.cs`

**Interfaces:** `AnnotationSession.Add(Annotation)`, `Undo()`, `Redo()`, `Annotations`; `AnnotationGeometry.IsMeaningful(Annotation)`.

- [ ] Write tests for zero-length arrow rejection, short rectangle rejection, undo and redo restoration, and redo invalidation after a new edit.
- [ ] Run core tests and confirm they fail for the absent behavior.
- [ ] Implement the annotation model and bounded snapshot history.
- [ ] Run core tests and confirm they pass. Commit.

### Task 3: Windows tray shell and capture selection

**Files:**
- Create: `Windows/Skreen2Go.Windows/Skreen2Go.Windows.csproj`
- Create: `Windows/Skreen2Go.Windows/App.xaml`
- Create: `Windows/Skreen2Go.Windows/App.xaml.cs`
- Create: `Windows/Skreen2Go.Windows/CaptureWindow.xaml`
- Create: `Windows/Skreen2Go.Windows/CaptureWindow.xaml.cs`
- Create: `Windows/Skreen2Go.Windows/DesktopCapture.cs`
- Create: `Windows/Skreen2Go.Windows/NativeMethods.cs`
- Create: `Windows/Skreen2Go.Windows/app.manifest`

**Interfaces:** `DesktopCapture.Snapshot(): Bitmap`, `CaptureWindow(Bitmap, RectangleI)` reports selected physical rectangle through `CaptureAccepted`, `App` owns tray and global shortcut.

- [ ] Add a core test for translating a virtual-screen rectangle with negative origin into bitmap-local crop coordinates. Run it red, implement, then run green.
- [ ] Build the WPF shell with a tray menu and Ctrl+Shift+S registration. Snapshot the desktop before showing the overlay.
- [ ] Implement drag selection and Escape cancellation; map WPF mouse positions to physical pixels through the window DPI transform.
- [ ] Run `dotnet build Windows/Skreen2Go.Windows/Skreen2Go.Windows.csproj` and a local smoke test. Commit.

### Task 4: Annotation editor and image output

**Files:**
- Create: `Windows/Skreen2Go.Windows/EditorWindow.xaml`
- Create: `Windows/Skreen2Go.Windows/EditorWindow.xaml.cs`
- Create: `Windows/Skreen2Go.Windows/ImageOutput.cs`
- Modify: `Windows/Skreen2Go.Windows/App.xaml.cs`
- Modify: `Windows/Skreen2Go.Windows.Core.Tests/Program.cs`

**Interfaces:** `ImageOutput.Render(Bitmap, IReadOnlyList<Annotation>): Bitmap`, `Save(Bitmap, string): string`, `Copy(Bitmap): void`.

- [ ] Write a real bitmap test: an annotated 200×100 image retains dimensions and contains the expected colored pixel. Run it red.
- [ ] Implement render/export, a simple editor for arrow, rectangle and text, and its copy/save actions. Use core history for undo/redo.
- [ ] Run tests and build; manually exercise drag, annotate, copy, save and cancel. Commit.

### Task 5: Documentation and integration gate

**Files:**
- Modify: `README.md`
- Modify: `WINDOWS-PORT.md`
- Modify: `.gitignore`

- [ ] Document Windows build/run steps and the actual features implemented; update the prior machine and SDK statements in `WINDOWS-PORT.md`.
- [ ] Run all core tests, build in Release, inspect `git diff --check`, and confirm the branch/worktree status.
- [ ] Commit documentation and report any remaining parity gaps explicitly.

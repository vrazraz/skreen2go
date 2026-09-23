# Windows port design

## Goal and scope

Build a native Windows desktop edition of Skreen2Go in the existing `windows-port` branch. The macOS code remains intact. The Windows edition retains the product workflow: launch from the notification area, invoke capture with a global shortcut, select a region or window, annotate it, copy or save an image, and record video with optional system and microphone audio.

The existing `WINDOWS-PORT.md` supplies the feature inventory and risk analysis. This document resolves the first implementation decisions for a Windows 11 development machine in September 2026.

## Platform and architecture

- Target Windows 11 and .NET 10 LTS. The desktop app is C# with WPF for ordinary controls and a borderless capture surface. Its process declares PerMonitorV2 DPI awareness.
- Keep a separate `Skreen2Go.Windows.Core` project for settings, selection geometry, annotation history, output naming, and recording state. It has no UI or native dependencies and can be tested without a screen.
- The app owns platform services behind small interfaces: global hotkeys, tray icon, desktop/window capture, clipboard and file output, and recording. Platform code is not mixed into the core models.
- Capture the virtual desktop before showing the selection overlay. This keeps the overlay and toolbar out of still images and permits seamless selection across monitors. Retain physical pixel coordinates from cursor input through crop/export; convert only at the WPF display boundary.
- Render annotations into the cropped bitmap at its original pixel size. The editor may scale the preview, but exports must preserve captured resolution.
- Record from a selected display or window with Windows Graphics Capture, encode H.264/AAC MP4 through Media Foundation, and acquire system/microphone audio through WASAPI. The recording service owns clock alignment and cleanup.
- Store settings as versioned JSON under `%LOCALAPPDATA%\Skreen2Go`. Default output goes to the user's Downloads folder. UI strings have English and Russian resources.

## User flow

The app starts in the notification area. Ctrl+Shift+S opens capture; Ctrl+Shift+R starts or stops recording. A drag selects a region; a click selects the top-level window under the pointer. After selection, the toolbar offers annotation tools, undo/redo, copy, save, save as, recording, settings, and cancel. Enter opens the larger editor. Escape closes the current overlay without output.

On copy, the app writes the finished image to the Windows clipboard. On save, it reserves a collision-free name and writes atomically to the chosen folder. Recording starts after a three-second countdown and stops from the same shortcut or tray. Errors appear in a message that identifies the failed operation and allows retry where safe.

## Delivery order and verification

1. Testable core: selection geometry, annotation validity/history, output paths, settings and recording state.
2. A runnable image capture path with tray, shortcut, overlay, editor, clipboard and file output. Verify on the local Windows 11 desktop and with automated core tests.
3. Recording spike, then integrated recording and audio. Verify ten-second MP4 playback, video dimensions, synchronized audio, cancellation and device loss.
4. Settings, localization, launch at login, notifications and packaging. Verify a clean install and a second launch with persisted settings.

The first runnable slice can use a WPF overlay to validate behavior. If full-screen interaction is visibly slow on high-resolution displays, replace its presentation layer with DirectComposition/Direct2D while preserving the core and platform service contracts. This is a measured performance decision, not a change to export semantics.

## Risks and limits

Screen capture of protected windows may return black or empty pixels; the app reports this rather than producing a misleading result. Windows Graphics Capture and audio behavior vary by device and privacy settings. Window exclusion and mixed-DPI capture are explicit manual verification cases. Signing credentials and store account setup are outside source control.

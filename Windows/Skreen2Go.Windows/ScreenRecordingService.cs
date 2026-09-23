using System.IO;
using ScreenRecorderLib;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

public sealed class ScreenRecordingService : IDisposable
{
    private Recorder? recorder;
    private TaskCompletionSource<string>? completion;

    public bool IsRecording => recorder is not null;

    public void Start(RecordingPlan plan, string path, bool captureSystemAudio,
        bool captureMicrophone, bool showCursor = true, bool showClicks = false)
    {
        if (recorder is not null) throw new InvalidOperationException("Recording is already active.");
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);

        var source = new DisplayRecordingSource(plan.DisplayName)
        {
            SourceRect = new ScreenRect(plan.SourceRect.X, plan.SourceRect.Y,
                plan.SourceRect.Width, plan.SourceRect.Height),
            IsCursorCaptureEnabled = showCursor
        };
        var audio = new AudioOptions { IsAudioEnabled = captureSystemAudio || captureMicrophone };
        if (captureSystemAudio) audio.AudioSources.Add(LoopbackAudioSource.Default);
        if (captureMicrophone) audio.AudioSources.Add(CaptureAudioSource.Default);
        var options = new RecorderOptions
        {
            SourceOptions = new SourceOptions { RecordingSources = [source] },
            OutputOptions = new OutputOptions
            {
                RecorderMode = RecorderMode.Video,
                OutputFrameSize = new ScreenSize(plan.PixelWidth, plan.PixelHeight)
            },
            AudioOptions = audio,
            MouseOptions = new MouseOptions
            {
                IsMousePointerEnabled = showCursor,
                IsMouseClicksDetected = showClicks
            },
            VideoEncoderOptions = new VideoEncoderOptions
            {
                Framerate = 30,
                IsHardwareEncodingEnabled = true,
                Encoder = new H264VideoEncoder()
            }
        };

        var created = Recorder.CreateRecorder(options);
        var done = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        created.OnRecordingComplete += (_, eventArgs) => done.TrySetResult(eventArgs.FilePath);
        created.OnRecordingFailed += (_, eventArgs) =>
            done.TrySetException(new InvalidOperationException(eventArgs.Error));
        try
        {
            created.Record(path);
            recorder = created;
            completion = done;
        }
        catch
        {
            created.Dispose();
            throw;
        }
    }

    public async Task<string> StopAsync()
    {
        var active = recorder ?? throw new InvalidOperationException("No recording is active.");
        var done = completion!;
        active.Stop();
        try
        {
            return await done.Task.WaitAsync(TimeSpan.FromSeconds(30));
        }
        finally
        {
            active.Dispose();
            recorder = null;
            completion = null;
        }
    }

    public void Dispose()
    {
        recorder?.Dispose();
        recorder = null;
        completion = null;
    }
}

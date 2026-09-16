using System.Text.Json;

namespace Codenotch.Windows;

public record Limit(double Used, int Minutes, DateTimeOffset? Reset);
public record Usage(DateTimeOffset Observed, Limit? Primary, Limit? Secondary)
{
    public bool Stale(DateTimeOffset now) => now - Observed > TimeSpan.FromMinutes(5) || Observed > now.AddMinutes(1);
}

public static class UsageParser
{
    public static Usage? Parse(string line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("type", out var type) || type.GetString() != "event_msg" ||
                !root.TryGetProperty("payload", out var p) || !p.TryGetProperty("type", out var kind) ||
                kind.GetString() != "token_count" || !p.TryGetProperty("rate_limits", out var limits) ||
                !root.TryGetProperty("timestamp", out var stamp) || !stamp.TryGetDateTimeOffset(out var at)) return null;
            Limit? Window(string key)
            {
                if (!limits.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object ||
                    !w.TryGetProperty("used_percent", out var value) || !value.TryGetDouble(out var used) ||
                    !double.IsFinite(used) || used < 0 || used > 100) return null;
                int minutes = w.TryGetProperty("window_minutes", out var m) && m.TryGetInt32(out var n) ? n : 0;
                DateTimeOffset? reset = null;
                if (w.TryGetProperty("resets_at", out var r) && r.TryGetInt64(out var seconds))
                    reset = DateTimeOffset.FromUnixTimeSeconds(seconds);
                return new(used, Math.Max(0, minutes), reset);
            }
            var primary = Window("primary"); var secondary = Window("secondary");
            return primary is null && secondary is null ? null : new(at, primary, secondary);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentOutOfRangeException or FormatException)
        { return null; }
    }
}

public static class CodexReader
{
    // Read only bounded tails. Never open auth.json or print/store transcript contents.
    public static Usage? Read(string home)
    {
        var root = Path.Combine(home, "sessions");
        if (!Directory.Exists(root)) return null;
        Usage? latest = null;
        try
        {
            // Date hierarchy: only the newest 20 dated directories, then 20 rollout files.
            var dirs = Directory.EnumerateDirectories(root).OrderDescending()
                .Take(2).SelectMany(y => Directory.EnumerateDirectories(y).OrderDescending().Take(3))
                .SelectMany(m => Directory.EnumerateDirectories(m).OrderDescending().Take(20))
                .OrderDescending().Take(20);
            var files = dirs.SelectMany(d => Directory.EnumerateFiles(d, "rollout-*.jsonl"))
                .OrderByDescending(File.GetLastWriteTimeUtc).Take(20);
            foreach (var file in files)
            {
                try
                {
                    using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    long start = Math.Max(0, stream.Length - 262144);
                    stream.Seek(start, SeekOrigin.Begin);
                    using var reader = new StreamReader(stream);
                    if (start > 0) reader.ReadLine(); // Discard incomplete first record.
                    var buffer = new char[262144];
                    int count = reader.ReadBlock(buffer, 0, buffer.Length);
                    foreach (var line in new string(buffer, 0, count).Split('\n'))
                    {
                        var found = UsageParser.Parse(line);
                        if (found is not null && (latest is null || found.Observed > latest.Observed)) latest = found;
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return latest;
    }
}

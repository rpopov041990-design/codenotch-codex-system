using Codenotch.Windows;
using System.Text.Json;

int passed = 0;
void Check(bool ok, string name) { if (!ok) throw new Exception(name); Console.WriteLine("PASS " + name); passed++; }
string Event(object? primary, object? secondary = null, string stamp = "2026-01-01T12:00:00Z") => JsonSerializer.Serialize(new { timestamp = stamp, type = "event_msg", payload = new { type = "token_count", rate_limits = new { primary, secondary } } });
var window = new { used_percent = 55, window_minutes = 10080, resets_at = 1800000000L };
var valid = Event(window);
var u = UsageParser.Parse(valid)!;
Check(u.Primary?.Used == 55 && u.Primary.Minutes == 10080, "percent is used, not remaining");
Check(u.Primary?.Reset == DateTimeOffset.FromUnixTimeSeconds(1800000000), "absolute reset");
Check(UsageParser.Parse("{incomplete") is null, "partial JSON");
Check(UsageParser.Parse(Event(new { used_percent = 101 })) is null, "out of range");
Check(UsageParser.Parse(Event(new { used_percent = -1 })) is null, "negative");
Check(UsageParser.Parse(Event(new { used_percent = "unknown" })) is null, "wrong type");
Check(UsageParser.Parse(Event(new { used_percent = 0 }))?.Primary?.Used == 0, "zero is valid");
Check(UsageParser.Parse(Event(null, window))?.Secondary?.Used == 55, "secondary-only");
Check(UsageParser.Parse(Event(window, stamp: "invalid")) is null, "missing source date");
Check(u.Stale(u.Observed.AddMinutes(6)), "old snapshot stale");
Check(u.Stale(u.Observed.AddMinutes(-2)), "future clock stale");
Check(!u.Stale(u.Observed.AddMinutes(1)), "recent snapshot");
string root = Path.Combine(Path.GetTempPath(), "codenotch-test-" + Guid.NewGuid());
try
{
    Check(CodexReader.Read(root) is null, "absent home");
    string day = Path.Combine(root, "sessions", "2026", "01", "01"); Directory.CreateDirectory(day);
    string file = Path.Combine(day, "rollout-test.jsonl");
    File.WriteAllText(file, valid + "\n" + "{partial");
    Check(CodexReader.Read(root)?.Primary?.Used == 55, "partial trailing record");
    Check(File.ReadAllText(file) == valid + "\n" + "{partial", "read-only logs");
    File.WriteAllText(file, new string('x', 300000) + "\n" + valid + "\n");
    Check(CodexReader.Read(root)?.Primary?.Used == 55, "bounded tail discards incomplete prefix");
    File.WriteAllText(Path.Combine(day, "rollout-new.jsonl"), Event(new { used_percent = 70 }, stamp: "2026-01-02T12:00:00Z"));
    Check(CodexReader.Read(root)?.Primary?.Used == 70, "newest source timestamp wins");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
Console.WriteLine($"{passed} tests passed");

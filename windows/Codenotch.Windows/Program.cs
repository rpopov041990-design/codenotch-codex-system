using System.Drawing.Drawing2D;

namespace Codenotch.Windows;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Local\\CodenotchCodexSystemWindows", out var first);
        if (!first) return;
        using var panel = new NotchForm(args.Contains("--smoke-test"));
        Application.Run(panel);
    }
}

sealed class NotchForm : Form
{
    readonly Sensors sensors = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 250 };
    readonly NotifyIcon tray;
    readonly ToolTip tip = new() { AutoPopDelay = 15000 };
    List<Metric> metrics = new();
    Usage? usage;
    bool expanded, pinned, loading;
    DateTime nextSensors = DateTime.MinValue, nextCodex = DateTime.MinValue, outside = DateTime.UtcNow;
    readonly bool smoke;
    readonly DateTime started = DateTime.UtcNow;
    float ScaleFactor => DeviceDpi / 96f;
    int Px(int n) => (int)Math.Round(n * ScaleFactor);

    public NotchForm(bool smokeTest)
    {
        smoke = smokeTest;
        Text = "Codenotch Windows · TEST";
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; BackColor = Color.FromArgb(23, 29, 40);
        DoubleBuffered = true; KeyPreview = true; AutoScaleMode = AutoScaleMode.None;
        var menu = new ContextMenuStrip();
        var pin = new ToolStripMenuItem("Закрепить раскрытой") { CheckOnClick = true };
        pin.CheckedChanged += (_, _) => { pinned = pin.Checked; SetExpanded(pinned); };
        menu.Items.Add(pin);
        menu.Items.Add("Показать / скрыть", null, (_, _) => { if (Visible) Hide(); else { Show(); Place(); } });
        menu.Items.Add("Выход", null, (_, _) => Close());
        ContextMenuStrip = menu;
        tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "Codenotch Windows · TEST", ContextMenuStrip = menu, Visible = !smoke };
        tray.DoubleClick += (_, _) => { Show(); SetExpanded(true); };
        MouseEnter += (_, _) => SetExpanded(true);
        MouseMove += (_, e) =>
        {
            int row = (e.Y - Px(12)) / Px(76);
            string text = row >= 0 && row < metrics.Count ? metrics[row].Detail : "";
            if (tip.GetToolTip(this) != text) tip.SetToolTip(this, text);
        };
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) { pinned = false; pin.Checked = false; SetExpanded(false); } };
        DpiChanged += (_, _) => Place();
        timer.Tick += async (_, _) =>
        {
            if (smoke && DateTime.UtcNow - started > TimeSpan.FromSeconds(2))
            {
                using var bitmap = new Bitmap(Width, Height);
                DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
                bitmap.Save(Path.Combine(AppContext.BaseDirectory, "Codenotch-smoke.png"));
                Close(); return;
            }
            if (!Visible) return;
            if (Bounds.Contains(Cursor.Position)) outside = DateTime.UtcNow;
            else if (!pinned && DateTime.UtcNow - outside > TimeSpan.FromMilliseconds(700)) SetExpanded(false);
            if (!expanded && !smoke) return;
            if (DateTime.UtcNow >= nextSensors) { nextSensors = DateTime.UtcNow.AddSeconds(3); RefreshMetrics(); }
            if (!smoke && !loading && DateTime.UtcNow >= nextCodex)
            {
                loading = true; nextCodex = DateTime.UtcNow.AddSeconds(60);
                string home = Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
                try { usage = await Task.Run(() => CodexReader.Read(home)); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
                { usage = null; }
                finally { loading = false; }
                if (!IsDisposed) RefreshMetrics();
            }
        };
        Shown += (_, _) => { RefreshMetrics(); if (smoke) { pinned = true; SetExpanded(true); } Place(); timer.Start(); };
        FormClosed += (_, _) => { timer.Stop(); tray.Visible = false; };
    }

    void RefreshMetrics()
    {
        var limit = usage?.Secondary ?? usage?.Primary;
        string detail = "Нет снимка лимитов. Выполните запрос в Codex. Проверяются только недавние локальные журналы; учётные данные не читаются.";
        if (usage is not null)
        {
            string Describe(string name, Limit? w) => w is null ? "" : $"{name}: {w.Used:0.#}% использовано, окно {w.Minutes} мин; сброс {(w.Reset?.ToLocalTime().ToString("g") ?? "неизвестен")}\n";
            detail = $"Локальный снимок {usage.Observed.ToLocalTime():g}" + (usage.Stale(DateTimeOffset.UtcNow) ? " — УСТАРЕЛ" : " — не онлайн-запрос") + "\n" + Describe("Основное", usage.Primary) + Describe("Дополнительное", usage.Secondary);
        }
        metrics = new() { new("Codex", limit?.Used, detail) };
        metrics.AddRange(sensors.Read());
        Place(); Invalidate();
    }

    void SetExpanded(bool value)
    {
        if (expanded == value) return;
        expanded = value; nextSensors = DateTime.MinValue; Place(); Invalidate();
    }

    void Place()
    {
        var area = Screen.PrimaryScreen!.WorkingArea;
        Size = new Size(Px(expanded ? 360 : 78), Math.Min(Px(Math.Max(1, metrics.Count) * 76 + 24), area.Height));
        Location = new Point(area.Right - Width, area.Top + (area.Height - Height) / 2);
        using var path = new GraphicsPath(); int radius = Px(24);
        path.AddArc(0, 0, radius, radius, 180, 90); path.AddArc(Width - radius, 0, radius, radius, 270, 90);
        path.AddArc(Width - radius, Height - radius, radius, radius, 0, 90); path.AddArc(0, Height - radius, radius, radius, 90, 90); path.CloseFigure();
        var old = Region; Region = new Region(path); old?.Dispose();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); var g = e.Graphics; g.ScaleTransform(ScaleFactor, ScaleFactor); g.SmoothingMode = SmoothingMode.AntiAlias;
        using var track = new Pen(Color.FromArgb(57, 66, 81), 5);
        using var arc = new Pen(Color.FromArgb(90, 214, 197), 5) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        using var title = new Font("Segoe UI", 12, FontStyle.Bold, GraphicsUnit.Pixel);
        using var detailFont = new Font("Segoe UI", 11, FontStyle.Regular, GraphicsUnit.Pixel);
        using var white = new SolidBrush(Color.WhiteSmoke); using var gray = new SolidBrush(Color.FromArgb(180, 191, 208));
        using var centered = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        using var clipped = new StringFormat { Trimming = StringTrimming.EllipsisCharacter };
        for (int i = 0; i < metrics.Count; i++)
        {
            var m = metrics[i]; int y = 12 + i * 76;
            g.DrawEllipse(track, 13, y, 50, 50);
            if (m.Percent is double value && value > 0) g.DrawArc(arc, 13, y, 50, 50, -90, (float)(value * 3.6));
            g.DrawString(m.Percent is double p ? $"{p:0}%" : "—", title, white, new RectangleF(13, y, 50, 50), centered);
            g.DrawString(m.Name, detailFont, gray, new RectangleF(2, y + 52, 72, 18), centered);
            if (expanded)
            {
                g.DrawString(m.Name + (i == 0 ? " · снимок" : ""), title, white, 84, y + 2);
                g.DrawString(m.Detail, detailFont, gray, new RectangleF(84, y + 23, 260, 47), clipped);
            }
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Dispose(); tray.Dispose(); tip.Dispose(); ContextMenuStrip?.Dispose(); }
        base.Dispose(disposing);
    }
}

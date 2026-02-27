
// Program.cs - Single file WinForms AGV Path Visualizer (C# 7.3)
// Recommended target: .NET Framework 4.7.2+ or 4.8
// Zoom + Pan added (mouse wheel zoom, middle/right drag pan)  //New

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using System.Drawing.Drawing2D;

namespace AgvPathViewer
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    // Double-buffered canvas to avoid flicker
    public sealed class DoubleBufferedPictureBox : PictureBox
    {
        public DoubleBufferedPictureBox()
        {
            DoubleBuffered = true;
            ResizeRedraw = true;
        }
    }

    public sealed class MainForm : Form
    {
        // ---------------- UI ----------------
        private readonly Panel _top;
        private readonly Button _btnLoadNodes;
        private readonly Button _btnLoadLogs;
        private readonly Button _btnClearLogs;
        private readonly CheckBox _chkAutoRefresh;
        private readonly Label _lblStatus;
        private readonly Button _btnResetView; //New

        private readonly DoubleBufferedPictureBox _canvas;

        // Debounce timer for file watcher bursts
        private readonly Timer _debounceTimer;

        // ---------------- Data ----------------
        private Dictionary<string, PointF> _nodes = new Dictionary<string, PointF>(StringComparer.OrdinalIgnoreCase);
        private readonly List<AgvSeries> _series = new List<AgvSeries>();

        // Watching updated logs
        private readonly List<FileSystemWatcher> _watchers = new List<FileSystemWatcher>();
        private bool _pendingRefresh;

        // View transform
        private RectangleF _worldBounds = new RectangleF(0, 0, 1, 1);
        private const float PaddingWorld = 20f;
        private const int PaddingPx = 30;
        private const float NodeRadiusPx = 4.5f;

        // Zoom/Pan state  //New
        private float _zoom = 1.0f;                 //New: 1 = fit-to-view baseline
        private PointF _panPx = new PointF(0, 0);   //New: pan offset in SCREEN pixels
        private bool _panning = false;              //New
        private Point _panStartMouse;               //New
        private PointF _panStartPanPx;              //New

        public MainForm()
        {
            Text = "AGV Movement Path Viewer (Nodes + Logs)";
            Width = 1200;
            Height = 800;
            StartPosition = FormStartPosition.CenterScreen;

            _top = new Panel { Dock = DockStyle.Top, Height = 56 };
            Controls.Add(_top);

            _btnLoadNodes = new Button { Text = "Load Nodes CSV", Left = 10, Top = 12, Width = 140, Height = 30 };
            _btnLoadNodes.Click += (s, e) => LoadNodesCsv();
            _top.Controls.Add(_btnLoadNodes);

            _btnLoadLogs = new Button { Text = "Load AGV Log CSV(s)", Left = 160, Top = 12, Width = 170, Height = 30 };
            _btnLoadLogs.Click += (s, e) => LoadAgvLogs();
            _top.Controls.Add(_btnLoadLogs);

            _btnClearLogs = new Button { Text = "Clear Logs", Left = 340, Top = 12, Width = 100, Height = 30 };
            _btnClearLogs.Click += (s, e) =>
            {
                _series.Clear();
                StopWatchers();
                UpdateStatus("Logs cleared.");
                Redraw();
            };
            _top.Controls.Add(_btnClearLogs);

            _chkAutoRefresh = new CheckBox { Text = "Auto-refresh on file change", Left = 460, Top = 17, Width = 220 };
            _chkAutoRefresh.CheckedChanged += (s, e) =>
            {
                if (_chkAutoRefresh.Checked) StartWatchers();
                else StopWatchers();
            };
            _top.Controls.Add(_chkAutoRefresh);

            _btnResetView = new Button { Text = "Reset View", Left = 690, Top = 12, Width = 100, Height = 30 }; //New
            _btnResetView.Click += (s, e) => ResetView(); //New
            _top.Controls.Add(_btnResetView); //New

            _lblStatus = new Label { Text = "Load nodes + logs to start.", Left = 800, Top = 18, AutoSize = true };
            _top.Controls.Add(_lblStatus);

            _canvas = new DoubleBufferedPictureBox { Dock = DockStyle.Fill, BackColor = Color.White };
            _canvas.Paint += Canvas_Paint;
            _canvas.Resize += (s, e) => Redraw();

            // Zoom + Pan mouse hooks  //New
            _canvas.MouseWheel += Canvas_MouseWheel;   //New
            _canvas.MouseDown += Canvas_MouseDown;     //New
            _canvas.MouseMove += Canvas_MouseMove;     //New
            _canvas.MouseUp += Canvas_MouseUp;         //New
            _canvas.MouseEnter += (s, e) => _canvas.Focus(); //New: ensure wheel works
            _canvas.TabStop = true; //New

            Controls.Add(_canvas);

            _debounceTimer = new Timer { Interval = 350 };
            _debounceTimer.Tick += (s, e) =>
            {
                _debounceTimer.Stop();
                if (_pendingRefresh)
                {
                    _pendingRefresh = false;
                    ReloadAllLogs();
                }
            };
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            StopWatchers();
            base.OnFormClosed(e);
        }

        // =========================
        // Zoom/Pan helpers  //New
        // =========================
        private void ResetView() //New
        {
            _zoom = 1f; //New
            _panPx = new PointF(0, 0); //New
            Redraw(); //New
        }

        private void Canvas_MouseWheel(object sender, MouseEventArgs e) //New
        {
            float oldZoom = _zoom; //New
            float factor = (e.Delta > 0) ? 1.15f : (1f / 1.15f); //New

            _zoom *= factor; //New
            _zoom = Clamp(_zoom, 0.2f, 12f); //New

            // Keep world point under cursor fixed (zoom around cursor) //New
            var worldUnderMouse = ScreenToWorld(e.Location, oldZoom, _panPx); //New
            var after = WorldToScreen(worldUnderMouse, _zoom, _panPx); //New

            _panPx = new PointF( //New
                _panPx.X + (e.X - after.X),
                _panPx.Y + (e.Y - after.Y)
            );

            Redraw(); //New
        }

        private void Canvas_MouseDown(object sender, MouseEventArgs e) //New
        {
            // Middle mouse or Right mouse to pan //New
            if (e.Button == MouseButtons.Middle || e.Button == MouseButtons.Right) //New
            {
                _panning = true; //New
                _panStartMouse = e.Location; //New
                _panStartPanPx = _panPx; //New
                _canvas.Cursor = Cursors.Hand; //New
            }
        }

        private void Canvas_MouseMove(object sender, MouseEventArgs e) //New
        {
            if (!_panning) return; //New

            int dx = e.X - _panStartMouse.X; //New
            int dy = e.Y - _panStartMouse.Y; //New

            _panPx = new PointF(_panStartPanPx.X + dx, _panStartPanPx.Y + dy); //New
            Redraw(); //New
        }

        private void Canvas_MouseUp(object sender, MouseEventArgs e) //New
        {
            if (_panning && (e.Button == MouseButtons.Middle || e.Button == MouseButtons.Right)) //New
            {
                _panning = false; //New
                _canvas.Cursor = Cursors.Default; //New
            }
        }

        private static float Clamp(float v, float min, float max) //New
        {
            if (v < min) return min;
            if (v > max) return max;
            return v;
        }

        // =========================
        // Loading CSVs
        // =========================
        private void LoadNodesCsv()
        {
            using (var ofd = new OpenFileDialog())
            {
                ofd.Title = "Select Nodes CSV";
                ofd.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*";
                ofd.Multiselect = false;

                if (ofd.ShowDialog(this) != DialogResult.OK) return;

                try
                {
                    _nodes = ParseNodesCsv(ofd.FileName);
                    ComputeWorldBounds();
                    ResetView(); //New: keep fit-to-view baseline after new bounds
                    UpdateStatus("Nodes loaded: " + _nodes.Count + " from " + Path.GetFileName(ofd.FileName));
                    Redraw();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to load nodes CSV:\n\n" + ex.Message, "Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void LoadAgvLogs()
        {
            if (_nodes.Count == 0)
            {
                MessageBox.Show(this, "Load Nodes CSV first (so node IDs can be mapped to X/Y).",
                    "Missing nodes", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            using (var ofd = new OpenFileDialog())
            {
                ofd.Title = "Select one or more AGV Log CSV files";
                ofd.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*";
                ofd.Multiselect = true;

                if (ofd.ShowDialog(this) != DialogResult.OK) return;

                try
                {
                    foreach (var file in ofd.FileNames)
                    {
                        var agvName = Path.GetFileNameWithoutExtension(file);

                        _series.RemoveAll(x => StringComparer.OrdinalIgnoreCase.Equals(x.FilePath, file));

                        var points = ParseAgvLogCsv(file, _nodes);

                        _series.Add(new AgvSeries
                        {
                            Name = agvName,
                            FilePath = file,
                            Points = points
                        });
                    }

                    AssignColors();
                    ComputeWorldBounds();
                    ResetView(); //New: show all after loading logs (optional but handy)
                    UpdateStatus("Logs loaded: " + _series.Count + " file(s). Total points: " + _series.Sum(s => s.Points.Count));
                    Redraw();

                    if (_chkAutoRefresh.Checked) StartWatchers();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to load AGV log CSV(s):\n\n" + ex.Message, "Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void ReloadAllLogs()
        {
            if (_nodes.Count == 0 || _series.Count == 0) return;

            int reloaded = 0;
            int totalPoints = 0;

            foreach (var s in _series)
            {
                try
                {
                    if (!File.Exists(s.FilePath)) continue;
                    s.Points = ParseAgvLogCsv(s.FilePath, _nodes);
                    reloaded++;
                    totalPoints += s.Points.Count;
                }
                catch
                {
                    // ignore individual file errors on auto refresh
                }
            }

            ComputeWorldBounds();
            // NOTE: Don't ResetView here, otherwise it will "snap back" while user is zoomed/panned  //New
            UpdateStatus("Auto-refreshed " + reloaded + " file(s). Total points: " + totalPoints);
            Redraw();
        }

        // =========================
        // CSV parsing
        // =========================
        private static Dictionary<string, PointF> ParseNodesCsv(string path)
        {
            var lines = File.ReadAllLines(path);
            if (lines.Length < 2) throw new Exception("Nodes CSV must have a header and at least 1 data row.");

            var header = SplitCsvLine(lines[0]);
            int iNode = FindCol(header, "node", "node_id", "id");
            int iX = FindCol(header, "x", "posx", "coordx");
            int iY = FindCol(header, "y", "posy", "coordy");

            if (iNode < 0 || iX < 0 || iY < 0)
                throw new Exception("Nodes CSV header must include columns: node,x,y (or aliases node_id/id, posx/coordx, posy/coordy).");

            var dict = new Dictionary<string, PointF>(StringComparer.OrdinalIgnoreCase);

            for (int r = 1; r < lines.Length; r++)
            {
                if (string.IsNullOrWhiteSpace(lines[r])) continue;
                var cols = SplitCsvLine(lines[r]);
                if (cols.Length <= Math.Max(iNode, Math.Max(iX, iY))) continue;

                var nodeId = (cols[iNode] ?? "").Trim();
                if (string.IsNullOrEmpty(nodeId)) continue;

                float x = ParseFloat(cols[iX]);
                float y = ParseFloat(cols[iY]);

                dict[nodeId] = new PointF(x, y);
            }

            if (dict.Count == 0) throw new Exception("No nodes parsed from nodes CSV.");
            return dict;
        }

        private static List<AgvPoint> ParseAgvLogCsv(string path, Dictionary<string, PointF> nodes)
        {
            string[] lines;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8, true))
            {
                var all = sr.ReadToEnd();
                lines = all.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
            }

            var nonEmpty = lines.Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
            if (nonEmpty.Length < 2) return new List<AgvPoint>();

            var header = SplitCsvLine(nonEmpty[0]);

            int iTs = FindCol(header, "timestamp", "time", "datetime", "ts");
            int iNode = FindCol(header, "node", "node_id", "id");

            if (iTs < 0 || iNode < 0)
                throw new Exception("Log CSV '" + Path.GetFileName(path) + "' must include columns: timestamp,node (or aliases).");

            var list = new List<AgvPoint>();

            for (int r = 1; r < nonEmpty.Length; r++)
            {
                var cols = SplitCsvLine(nonEmpty[r]);
                if (cols.Length <= Math.Max(iTs, iNode)) continue;

                var tsStr = (cols[iTs] ?? "").Trim();
                var nodeId = (cols[iNode] ?? "").Trim();
                if (string.IsNullOrEmpty(nodeId)) continue;

                PointF xy;
                if (!nodes.TryGetValue(nodeId, out xy))
                    continue;

                DateTime ts;
                if (!TryParseDate(tsStr, out ts))
                    continue;

                list.Add(new AgvPoint { Time = ts, NodeId = nodeId, XY = xy });
            }

            list.Sort((a, b) => a.Time.CompareTo(b.Time));

            var compressed = new List<AgvPoint>(list.Count);
            string last = null;
            for (int i = 0; i < list.Count; i++)
            {
                if (!string.Equals(last, list[i].NodeId, StringComparison.OrdinalIgnoreCase))
                {
                    compressed.Add(list[i]);
                    last = list[i].NodeId;
                }
            }

            return compressed;
        }

        private static bool TryParseDate(string s, out DateTime dt)
        {
            var formats = new[]
            {
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss.fff",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy.MM.dd HH:mm:ss",
                "dd.MM.yyyy HH:mm:ss",
                "dd/MM/yyyy HH:mm:ss",
                "MM/dd/yyyy HH:mm:ss",
                "yyyy-MM-ddTHH:mm:ss",
                "yyyy-MM-ddTHH:mm:ss.fff"
            };

            if (DateTime.TryParseExact(s, formats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out dt))
                return true;

            return DateTime.TryParse(s, CultureInfo.CurrentCulture, DateTimeStyles.AssumeLocal, out dt)
                || DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out dt);
        }

        private static float ParseFloat(string s)
        {
            s = (s ?? "").Trim();
            float f;

            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out f)) return f;
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.CurrentCulture, out f)) return f;

            s = s.Replace(',', '.');
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out f)) return f;

            throw new Exception("Could not parse float: " + s);
        }

        private static int FindCol(string[] header, params string[] names)
        {
            for (int i = 0; i < header.Length; i++)
            {
                var h = (header[i] ?? "").Trim().Trim('"').ToLowerInvariant();
                for (int j = 0; j < names.Length; j++)
                {
                    if (h == names[j].ToLowerInvariant())
                        return i;
                }
            }
            return -1;
        }

        private static string[] SplitCsvLine(string line)
        {
            if (line == null) return new string[0];

            var result = new List<string>();
            var sb = new StringBuilder();
            bool inQuotes = false;

            for (int i = 0; i < line.Length; i++)
            {
                char c = line[i];

                if (c == '"')
                {
                    if (inQuotes && i + 1 < line.Length && line[i + 1] == '"')
                    {
                        sb.Append('"');
                        i++;
                    }
                    else
                    {
                        inQuotes = !inQuotes;
                    }
                }
                else if (c == ',' && !inQuotes)
                {
                    result.Add(sb.ToString());
                    sb.Clear();
                }
                else
                {
                    sb.Append(c);
                }
            }

            result.Add(sb.ToString());
            return result.ToArray();
        }

        // =========================
        // File watching
        // =========================
        private void StartWatchers()
        {
            StopWatchers();

            var dirs = _series
                .Select(s => s.FilePath)
                .Where(p => !string.IsNullOrWhiteSpace(p))
                .Select(p => Path.GetDirectoryName(p))
                .Where(d => !string.IsNullOrWhiteSpace(d))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            foreach (var dir in dirs)
            {
                try
                {
                    var w = new FileSystemWatcher(dir);
                    w.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName;
                    w.Filter = "*.csv";
                    w.Changed += WatcherEvent;
                    w.Created += WatcherEvent;
                    w.Renamed += WatcherEvent;
                    w.EnableRaisingEvents = true;
                    _watchers.Add(w);
                }
                catch { }
            }

            UpdateStatus("Auto-refresh watching " + _watchers.Count + " folder(s).");
        }

        private void StopWatchers()
        {
            for (int i = 0; i < _watchers.Count; i++)
            {
                try
                {
                    _watchers[i].EnableRaisingEvents = false;
                    _watchers[i].Dispose();
                }
                catch { }
            }
            _watchers.Clear();
        }

        private void WatcherEvent(object sender, FileSystemEventArgs e)
        {
            if (!_series.Any(s => StringComparer.OrdinalIgnoreCase.Equals(s.FilePath, e.FullPath)))
                return;

            _pendingRefresh = true;
            _debounceTimer.Stop();
            _debounceTimer.Start();
        }

        // =========================
        // Rendering
        // =========================
        private void ComputeWorldBounds()
        {
            var pts = new List<PointF>();
            pts.AddRange(_nodes.Values);
            foreach (var s in _series)
                pts.AddRange(s.Points.Select(p => p.XY));

            if (pts.Count == 0)
            {
                _worldBounds = new RectangleF(0, 0, 1, 1);
                return;
            }

            float minX = pts.Min(p => p.X);
            float maxX = pts.Max(p => p.X);
            float minY = pts.Min(p => p.Y);
            float maxY = pts.Max(p => p.Y);

            minX -= PaddingWorld;
            minY -= PaddingWorld;
            maxX += PaddingWorld;
            maxY += PaddingWorld;

            float w = Math.Max(1e-3f, maxX - minX);
            float h = Math.Max(1e-3f, maxY - minY);

            _worldBounds = new RectangleF(minX, minY, w, h);
        }

        private void AssignColors()
        {
            var palette = new[]
            {
                Color.FromArgb(0, 120, 215),
                Color.FromArgb(232, 17, 35),
                Color.FromArgb(16, 124, 16),
                Color.FromArgb(255, 140, 0),
                Color.FromArgb(136, 23, 152),
                Color.FromArgb(0, 153, 188),
                Color.FromArgb(215, 186, 0),
                Color.FromArgb(118, 118, 118),
            };

            for (int i = 0; i < _series.Count; i++)
                _series[i].Color = palette[i % palette.Length];
        }

        private void Redraw()
        {
            _canvas.Invalidate();
        }

        private void Canvas_Paint(object sender, PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.White);

            DrawGrid(g);

            for (int i = 0; i < _series.Count; i++)
                DrawSeriesPath(g, _series[i]);

            DrawNodes(g);

            DrawLegend(g);
        }

        private void DrawGrid(Graphics g)
        {
            using (var pen = new Pen(Color.FromArgb(235, 235, 235), 1))
            {
                int step = 50;
                for (int x = 0; x < _canvas.Width; x += step)
                    g.DrawLine(pen, x, 0, x, _canvas.Height);

                for (int y = 0; y < _canvas.Height; y += step)
                    g.DrawLine(pen, 0, y, _canvas.Width, y);
            }
        }

        private void DrawNodes(Graphics g)
        {
            if (_nodes.Count == 0) return;

            using (var nodeBrush = new SolidBrush(Color.Black))
            using (var labelBrush = new SolidBrush(Color.FromArgb(60, 60, 60)))
            using (var font = new Font("Segoe UI", 8f))
            {
                foreach (var kv in _nodes)
                {
                    var p = WorldToScreen(kv.Value);
                    g.FillEllipse(nodeBrush, p.X - NodeRadiusPx, p.Y - NodeRadiusPx, NodeRadiusPx * 2, NodeRadiusPx * 2);
                    g.DrawString(kv.Key, font, labelBrush, p.X + 6, p.Y + 3);
                }
            }
        }

        private void DrawSeriesPath(Graphics g, AgvSeries s)
        {
            if (s.Points == null || s.Points.Count < 2) return;

            using (var pen = new Pen(s.Color, 2.2f))
            using (var headBrush = new SolidBrush(s.Color))
            {
                PointF prev = WorldToScreen(s.Points[0].XY);
                for (int i = 1; i < s.Points.Count; i++)
                {
                    var cur = WorldToScreen(s.Points[i].XY);
                    g.DrawLine(pen, prev, cur);
                    prev = cur;
                }

                var last = WorldToScreen(s.Points[s.Points.Count - 1].XY);
                g.FillEllipse(headBrush, last.X - 6, last.Y - 6, 12, 12);
            }
        }

        private void DrawLegend(Graphics g)
        {
            if (_series.Count == 0) return;

            int x = 10;
            int y = _top.Bottom + 10;

            using (var font = new Font("Segoe UI", 9f))
            {
                foreach (var s in _series)
                {
                    using (var b = new SolidBrush(s.Color))
                        g.FillRectangle(b, x, y + 4, 14, 14);

                    g.DrawRectangle(Pens.Black, x, y + 4, 14, 14);

                    g.DrawString(s.Name + " (" + s.Points.Count + " pts)", font, Brushes.Black, x + 22, y + 2);
                    y += 22;
                }
            }
        }

        // World->Screen with zoom + pan  //New
        private PointF WorldToScreen(PointF w) //New (updated)
        {
            return WorldToScreen(w, _zoom, _panPx); //New
        }

        private PointF WorldToScreen(PointF w, float zoom, PointF panPx) //New
        {
            var rect = _worldBounds;

            int W = Math.Max(1, _canvas.Width);
            int H = Math.Max(1, _canvas.Height);

            float usableW = Math.Max(1f, W - 2 * PaddingPx);
            float usableH = Math.Max(1f, H - 2 * PaddingPx);

            float sx = usableW / rect.Width;
            float sy = usableH / rect.Height;
            float baseS = Math.Min(sx, sy);

            float s = baseS * zoom;

            float drawW = rect.Width * s;
            float drawH = rect.Height * s;

            float ox = (W - drawW) / 2f;
            float oy = (H - drawH) / 2f;

            float x = ox + (w.X - rect.Left) * s + panPx.X;
            float y = oy + (rect.Bottom - w.Y) * s + panPx.Y; // flip Y

            return new PointF(x, y);
        }

        // Screen->World for zoom-around-cursor  //New
        private PointF ScreenToWorld(Point screenPt, float zoom, PointF panPx) //New
        {
            var rect = _worldBounds;

            int W = Math.Max(1, _canvas.Width);
            int H = Math.Max(1, _canvas.Height);

            float usableW = Math.Max(1f, W - 2 * PaddingPx);
            float usableH = Math.Max(1f, H - 2 * PaddingPx);

            float sx = usableW / rect.Width;
            float sy = usableH / rect.Height;
            float baseS = Math.Min(sx, sy);

            float s = baseS * zoom;

            float drawW = rect.Width * s;
            float drawH = rect.Height * s;

            float ox = (W - drawW) / 2f;
            float oy = (H - drawH) / 2f;

            float x = (screenPt.X - ox - panPx.X) / s + rect.Left;
            float y = rect.Bottom - ((screenPt.Y - oy - panPx.Y) / s);

            return new PointF(x, y);
        }

        private void UpdateStatus(string msg)
        {
            _lblStatus.Text = msg;
        }

        // =========================
        // Models
        // =========================
        private sealed class AgvPoint
        {
            public DateTime Time;
            public string NodeId;
            public PointF XY;
        }

        private sealed class AgvSeries
        {
            public string Name;
            public string FilePath;
            public List<AgvPoint> Points = new List<AgvPoint>();
            public Color Color = Color.Blue;
        }
    }
}
// Program.cs - Single file WinForms AGV Path Visualizer (C# 7.3)
// Target: .NET Framework 4.7.2+ or 4.8 (recommended)
// Features:
// - Load Nodes CSV (node,x,y)  (supports , ; tab delimiters)
// - Load one/many AGV log CSVs (timestamp,node) (supports , ; tab delimiters)
// - Visual map: nodes + paths + last position marker (draws even if only 1 point)
// - Zoom (mouse wheel, zoom around cursor) + Pan (middle/right mouse drag)
// - Optional auto-refresh using FileSystemWatcher (hourly overwritten logs)

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
        private readonly Button _btnResetView;
        private readonly Label _lblStatus;

        private readonly DoubleBufferedPictureBox _canvas;
        private readonly Timer _debounceTimer;

        // ---------------- Data ----------------
        private Dictionary<string, PointF> _nodes = new Dictionary<string, PointF>(StringComparer.OrdinalIgnoreCase);
        private readonly List<AgvSeries> _series = new List<AgvSeries>();

        // Watching updated logs
        private readonly List<FileSystemWatcher> _watchers = new List<FileSystemWatcher>();
        private bool _pendingRefresh;

        // World bounds
        private RectangleF _worldBounds = new RectangleF(0, 0, 1, 1);
        private const float PaddingWorld = 20f;
        private const int PaddingPx = 30;
        private const float NodeRadiusPx = 4.5f;

        // Zoom/Pan state
        private float _zoom = 1.0f;                 // 1 = fit-to-view baseline
        private PointF _panPx = new PointF(0, 0);   // pan offset in SCREEN pixels
        private bool _panning = false;
        private Point _panStartMouse;
        private PointF _panStartPanPx;

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

            _btnResetView = new Button { Text = "Reset View", Left = 690, Top = 12, Width = 100, Height = 30 };
            _btnResetView.Click += (s, e) => ResetView();
            _top.Controls.Add(_btnResetView);

            _lblStatus = new Label { Text = "Load nodes + logs to start.", Left = 800, Top = 18, AutoSize = true };
            _top.Controls.Add(_lblStatus);

            _canvas = new DoubleBufferedPictureBox { Dock = DockStyle.Fill, BackColor = Color.White, TabStop = true };
            _canvas.Paint += Canvas_Paint;
            _canvas.Resize += (s, e) => Redraw();

            // Zoom + Pan mouse hooks
            _canvas.MouseWheel += Canvas_MouseWheel;
            _canvas.MouseDown += Canvas_MouseDown;
            _canvas.MouseMove += Canvas_MouseMove;
            _canvas.MouseUp += Canvas_MouseUp;
            _canvas.MouseEnter += (s, e) => _canvas.Focus(); // ensure wheel works

            Controls.Add(_canvas);

            // Debounce timer for file watcher bursts
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
        // Zoom / Pan
        // =========================
        private void ResetView()
        {
            _zoom = 1f;
            _panPx = new PointF(0, 0);
            Redraw();
        }

        private void Canvas_MouseWheel(object sender, MouseEventArgs e)
        {
            float oldZoom = _zoom;
            float factor = (e.Delta > 0) ? 1.15f : (1f / 1.15f);

            _zoom *= factor;
            _zoom = Clamp(_zoom, 0.2f, 12f);

            // zoom around cursor
            var worldUnderMouse = ScreenToWorld(e.Location, oldZoom, _panPx);
            var after = WorldToScreen(worldUnderMouse, _zoom, _panPx);

            _panPx = new PointF(
                _panPx.X + (e.X - after.X),
                _panPx.Y + (e.Y - after.Y)
            );

            Redraw();
        }

        private void Canvas_MouseDown(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Middle || e.Button == MouseButtons.Right)
            {
                _panning = true;
                _panStartMouse = e.Location;
                _panStartPanPx = _panPx;
                _canvas.Cursor = Cursors.Hand;
            }
        }

        private void Canvas_MouseMove(object sender, MouseEventArgs e)
        {
            if (!_panning) return;

            int dx = e.X - _panStartMouse.X;
            int dy = e.Y - _panStartMouse.Y;

            _panPx = new PointF(_panStartPanPx.X + dx, _panStartPanPx.Y + dy);
            Redraw();
        }

        private void Canvas_MouseUp(object sender, MouseEventArgs e)
        {
            if (_panning && (e.Button == MouseButtons.Middle || e.Button == MouseButtons.Right))
            {
                _panning = false;
                _canvas.Cursor = Cursors.Default;
            }
        }

        private static float Clamp(float v, float min, float max)
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
                    ResetView();
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

                        // Replace if already loaded
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
                    ResetView();

                    UpdateStatus("Logs loaded: " + _series.Count + " file(s). Total points: " + _series.Sum(s => s.Points.Count));
                    Redraw();

                    if (_chkAutoRefresh.Checked) StartWatchers();
                }
                catch (Exception ex)
                {
                    // IMPORTANT: ParseAgvLogCsv will throw detailed reasons if it ends up with 0 points
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
            // do NOT ResetView here (would snap zoom/pan while user is viewing)
            UpdateStatus("Auto-refreshed " + reloaded + " file(s). Total points: " + totalPoints);
            Redraw();
        }

        // =========================
        // CSV parsing (supports , ; tab)
        // =========================
        private static char DetectDelimiter(string line)
        {
            if (string.IsNullOrEmpty(line)) return ',';
            int commas = line.Count(c => c == ',');
            int semis = line.Count(c => c == ';');
            int tabs = line.Count(c => c == '\t');

            if (semis >= commas && semis >= tabs && semis > 0) return ';';
            if (tabs >= commas && tabs >= semis && tabs > 0) return '\t';
            return ',';
        }

        private static string[] SplitCsvLine(string line, char delimiter)
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
                else if (c == delimiter && !inQuotes)
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

        private static int FindCol(string[] header, params string[] names)
        {
            for (int i = 0; i < header.Length; i++)
            {
                var hRaw = (header[i] ?? "");
                var h = hRaw.Trim().Trim('"').Trim('\uFEFF').ToLowerInvariant();
                var hNorm = new string(h.Where(ch => ch != ' ' && ch != '_' && ch != '-').ToArray());

                for (int j = 0; j < names.Length; j++)
                {
                    var n = names[j].ToLowerInvariant();
                    var nNorm = new string(n.Where(ch => ch != ' ' && ch != '_' && ch != '-').ToArray());

                    if (h == n || hNorm == nNorm)
                        return i;
                }
            }
            return -1;
        }

        private static Dictionary<string, PointF> ParseNodesCsv(string path)
        {
            var lines = File.ReadAllLines(path);
            if (lines.Length < 2) throw new Exception("Nodes CSV must have a header and at least 1 data row.");

            char delim = DetectDelimiter(lines[0]);
            var header = SplitCsvLine(lines[0], delim);

            int iNode = FindCol(header, "node", "nodeid", "node_id", "id", "name");
            int iX = FindCol(header, "x", "posx", "coordx", "xcoord");
            int iY = FindCol(header, "y", "posy", "coordy", "ycoord");

            if (iNode < 0 || iX < 0 || iY < 0)
                throw new Exception(
                    "Nodes CSV header not recognized.\n\n" +
                    "Found columns: [" + string.Join(", ", header.Select(h => (h ?? "").Trim())) + "]\n" +
                    "Expected something like: node,x,y (delimiter may be ';' or ',')."
                );

            var dict = new Dictionary<string, PointF>(StringComparer.OrdinalIgnoreCase);

            for (int r = 1; r < lines.Length; r++)
            {
                if (string.IsNullOrWhiteSpace(lines[r])) continue;
                var cols = SplitCsvLine(lines[r], delim);
                if (cols.Length <= Math.Max(iNode, Math.Max(iX, iY))) continue;

                var nodeId = (cols[iNode] ?? "").Trim().Trim('"').Trim();
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
            // Robust read even if file is being written
            string[] lines;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8, true))
            {
                var all = sr.ReadToEnd();
                lines = all.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
            }

            var nonEmpty = lines.Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
            if (nonEmpty.Length < 2) return new List<AgvPoint>();

            char delim = DetectDelimiter(nonEmpty[0]);
            var header = SplitCsvLine(nonEmpty[0], delim);

            int iTs = FindCol(header, "timestamp", "time", "datetime", "ts", "date", "datum", "ido", "idopont");
            int iNode = FindCol(header, "node", "nodeid", "node_id", "id", "csomopont", "allomas");

            if (iTs < 0 || iNode < 0)
                throw new Exception(
                    "Log CSV '" + Path.GetFileName(path) + "' header not recognized.\n\n" +
                    "Delimiter detected: '" + (delim == '\t' ? "\\t" : delim.ToString()) + "'\n" +
                    "Found columns: [" + string.Join(", ", header.Select(h => (h ?? "").Trim())) + "]\n" +
                    "Expected something like: timestamp,node (or HU-like date/node columns)."
                );

            // debug counters (to explain 0 pts)
            int totalRows = 0;
            int shortRow = 0;
            int emptyNode = 0;
            int unknownNode = 0;
            int badDate = 0;

            var list = new List<AgvPoint>();

            for (int r = 1; r < nonEmpty.Length; r++)
            {
                var cols = SplitCsvLine(nonEmpty[r], delim);
                totalRows++;

                if (cols.Length <= Math.Max(iTs, iNode)) { shortRow++; continue; }

                var tsStr = (cols[iTs] ?? "").Trim().Trim('"').Trim();
                var nodeId = (cols[iNode] ?? "").Trim().Trim('"').Trim();

                if (string.IsNullOrEmpty(nodeId)) { emptyNode++; continue; }

                PointF xy;
                if (!nodes.TryGetValue(nodeId, out xy)) { unknownNode++; continue; }

                DateTime ts;
                if (!TryParseDate(tsStr, out ts)) { badDate++; continue; }

                list.Add(new AgvPoint { Time = ts, NodeId = nodeId, XY = xy });
            }

            list.Sort((a, b) => a.Time.CompareTo(b.Time));

            // compress consecutive duplicates (keeps path clean). If you want every row, return list instead.
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

            if (compressed.Count == 0)
            {
                throw new Exception(
                    "0 points parsed from '" + Path.GetFileName(path) + "'.\n\n" +
                    "Delimiter detected: '" + (delim == '\t' ? "\\t" : delim.ToString()) + "'\n" +
                    "Rows read: " + totalRows + "\n" +
                    "Skipped: shortRow=" + shortRow +
                    ", emptyNode=" + emptyNode +
                    ", unknownNode=" + unknownNode +
                    ", badDate=" + badDate + "\n\n" +
                    "Most common fixes:\n" +
                    "- Node IDs in log must exist in nodes.csv (unknownNode > 0 means mismatch)\n" +
                    "- Timestamp format must be parseable (badDate > 0 means date format issue)\n" +
                    "- CSV delimiter should be ',' or ';' (auto-detected here)"
                );
            }

            return compressed;
        }

        private static bool TryParseDate(string s, out DateTime dt)
        {
            var formats = new[]
            {
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss.fff",
                "yyyy-MM-dd HH:mm:ss,fff",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy.MM.dd HH:mm:ss",
                "yyyy.MM.dd HH:mm:ss.fff",
                "yyyy.MM.dd HH:mm:ss,fff",
                "dd.MM.yyyy HH:mm:ss",
                "dd.MM.yyyy HH:mm:ss.fff",
                "dd.MM.yyyy HH:mm:ss,fff",
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
            s = (s ?? "").Trim().Trim('"').Trim();
            float f;

            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out f)) return f;
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.CurrentCulture, out f)) return f;

            s = s.Replace(',', '.');
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out f)) return f;

            throw new Exception("Could not parse float: " + s);
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
            if (s.Points == null || s.Points.Count == 0) return;

            using (var pen = new Pen(s.Color, 2.2f))
            using (var headBrush = new SolidBrush(s.Color))
            {
                // draw even if only 1 point
                if (s.Points.Count == 1)
                {
                    var only = WorldToScreen(s.Points[0].XY);
                    g.FillEllipse(headBrush, only.X - 6, only.Y - 6, 12, 12);
                    return;
                }

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

        // World->Screen with zoom + pan
        private PointF WorldToScreen(PointF w)
        {
            return WorldToScreen(w, _zoom, _panPx);
        }

        private PointF WorldToScreen(PointF w, float zoom, PointF panPx)
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

        // Screen->World for zoom-around-cursor
        private PointF ScreenToWorld(Point screenPt, float zoom, PointF panPx)
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
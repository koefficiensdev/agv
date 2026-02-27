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
        private readonly Panel _top;
        private readonly Button _btnLoadNodes;
        private readonly Button _btnLoadLogs;
        private readonly Button _btnClearLogs;
        private readonly CheckBox _chkAutoRefresh;
        private readonly Button _btnResetView;
        private readonly Label _lblStatus;

        private readonly DoubleBufferedPictureBox _canvas;
        private readonly Timer _debounceTimer;

        private Dictionary<string, PointF> _nodes = new Dictionary<string, PointF>(StringComparer.OrdinalIgnoreCase);
        private readonly List<AgvSeries> _series = new List<AgvSeries>();

        private readonly List<FileSystemWatcher> _watchers = new List<FileSystemWatcher>();
        private bool _pendingRefresh;

        private RectangleF _worldBounds = new RectangleF(0, 0, 1, 1);
        private const float PaddingWorld = 20f;
        private const int PaddingPx = 30;
        private const float NodeRadiusPx = 4.5f;

        private float _zoom = 1.0f;
        private PointF _panPx = new PointF(0, 0);
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

            _canvas.MouseWheel += Canvas_MouseWheel;
            _canvas.MouseDown += Canvas_MouseDown;
            _canvas.MouseMove += Canvas_MouseMove;
            _canvas.MouseUp += Canvas_MouseUp;
            _canvas.MouseEnter += (s, e) => _canvas.Focus();

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
                MessageBox.Show(this, "Load Nodes CSV first.", "Missing nodes", MessageBoxButtons.OK, MessageBoxIcon.Warning);
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

                        var points = ParseAgvLogCsv_NoDate(file, _nodes);

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
                    s.Points = ParseAgvLogCsv_NoDate(s.FilePath, _nodes);
                    reloaded++;
                    totalPoints += s.Points.Count;
                }
                catch
                {
                }
            }

            ComputeWorldBounds();
            UpdateStatus("Auto-refreshed " + reloaded + " file(s). Total points: " + totalPoints);
            Redraw();
        }

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
                throw new Exception("Nodes CSV header not recognized. Found: [" + string.Join(", ", header.Select(h => (h ?? "").Trim())) + "]");

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

        private static List<AgvPoint> ParseAgvLogCsv_NoDate(string path, Dictionary<string, PointF> nodes)
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

            char delim = DetectDelimiter(nonEmpty[0]);
            var header = SplitCsvLine(nonEmpty[0], delim);

            int iNode = FindCol(header, "node", "nodeid", "node_id", "id", "csomopont", "allomas");
            if (iNode < 0)
                throw new Exception("Log CSV '" + Path.GetFileName(path) + "' needs a node column. Found: [" + string.Join(", ", header.Select(h => (h ?? "").Trim())) + "]");

            int totalRows = 0;
            int shortRow = 0;
            int emptyNode = 0;
            int unknownNode = 0;

            var list = new List<AgvPoint>();
            int step = 0;

            for (int r = 1; r < nonEmpty.Length; r++)
            {
                var cols = SplitCsvLine(nonEmpty[r], delim);
                totalRows++;

                if (cols.Length <= iNode) { shortRow++; continue; }

                var nodeId = (cols[iNode] ?? "").Trim().Trim('"').Trim();
                if (string.IsNullOrEmpty(nodeId)) { emptyNode++; continue; }

                PointF xy;
                if (!nodes.TryGetValue(nodeId, out xy)) { unknownNode++; continue; }

                step++;
                list.Add(new AgvPoint { Step = step, NodeId = nodeId, XY = xy });
            }

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
                    "0 points parsed from '" + Path.GetFileName(path) + "'. Rows=" + totalRows +
                    ", shortRow=" + shortRow + ", emptyNode=" + emptyNode + ", unknownNode=" + unknownNode
                );
            }

            return compressed;
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
                catch
                {
                }
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
                catch
                {
                }
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

            if (s.Points.Count == 1)
            {
                var only = WorldToScreen(s.Points[0].XY);
                using (var headBrush = new SolidBrush(s.Color))
                {
                    g.FillEllipse(headBrush, only.X - 6, only.Y - 6, 12, 12);
                }
                return;
            }

            var edgeCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < s.Points.Count; i++)
            {
                var key = EdgeKeyDirected(s.Points[i - 1].NodeId, s.Points[i].NodeId);
                int c;
                if (!edgeCounts.TryGetValue(key, out c)) c = 0;
                edgeCounts[key] = c + 1;
            }

            for (int i = 1; i < s.Points.Count; i++)
            {
                var a = s.Points[i - 1];
                var b = s.Points[i];

                var key = EdgeKeyDirected(a.NodeId, b.NodeId);
                int c = edgeCounts[key];

                Color col;
                if (c <= 1) col = BlendWithWhite(s.Color, 0.65f);
                else if (c == 2) col = BlendWithWhite(s.Color, 0.35f);
                else col = s.Color;

                float width = (c <= 1) ? 2.0f : (c == 2 ? 2.8f : 3.6f);

                using (var pen = new Pen(col, width))
                {
                    var p1 = WorldToScreen(a.XY);
                    var p2 = WorldToScreen(b.XY);
                    g.DrawLine(pen, p1, p2);
                }
            }

            var last = WorldToScreen(s.Points[s.Points.Count - 1].XY);
            using (var headBrush = new SolidBrush(s.Color))
            {
                g.FillEllipse(headBrush, last.X - 6, last.Y - 6, 12, 12);
            }
        }

        private static string EdgeKeyDirected(string a, string b)
        {
            a = (a ?? "").Trim();
            b = (b ?? "").Trim();
            return a + "->" + b;
        }

        private static Color BlendWithWhite(Color baseColor, float t)
        {
            if (t < 0f) t = 0f;
            if (t > 1f) t = 1f;

            int r = (int)Math.Round(baseColor.R + (255 - baseColor.R) * t);
            int g = (int)Math.Round(baseColor.G + (255 - baseColor.G) * t);
            int b = (int)Math.Round(baseColor.B + (255 - baseColor.B) * t);

            if (r < 0) r = 0; if (r > 255) r = 255;
            if (g < 0) g = 0; if (g > 255) g = 255;
            if (b < 0) b = 0; if (b > 255) b = 255;

            return Color.FromArgb(r, g, b);
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
            float y = oy + (rect.Bottom - w.Y) * s + panPx.Y;

            return new PointF(x, y);
        }

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

        private sealed class AgvPoint
        {
            public int Step;
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
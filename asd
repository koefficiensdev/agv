using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
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

    [DataContract]
    public sealed class LayoutFile
    {
        [DataMember] public List<LayoutItem> Items { get; set; } = new List<LayoutItem>();
    }

    [DataContract]
    public sealed class LayoutItem
    {
        [DataMember] public string Type { get; set; }
        [DataMember] public float X { get; set; }
        [DataMember] public float Y { get; set; }
        [DataMember] public float W { get; set; }
        [DataMember] public float H { get; set; }
        [DataMember] public string Text { get; set; }
    }

    public sealed class MainForm : Form
    {
        private readonly Panel _top;
        private readonly Button _btnLoadNodes;
        private readonly Button _btnLoadLogs;
        private readonly Button _btnClearLogs;
        private readonly CheckBox _chkAutoRefresh;
        private readonly Button _btnResetView;
        private readonly CheckBox _chkShowNodeLabels;

        private readonly CheckBox _chkBuilderMode;
        private readonly Button _btnToolSelect;
        private readonly Button _btnToolRect;
        private readonly Button _btnToolText;
        private readonly Button _btnSaveLayout;
        private readonly Button _btnLoadLayout;
        private readonly Button _btnClearLayout;

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

        private readonly LayoutFile _layout = new LayoutFile();
        private LayoutItem _selectedLayoutItem = null;

        private enum BuilderTool { Select, Rect, Text }
        private BuilderTool _builderTool = BuilderTool.Select;

        private bool _creatingRect = false;
        private PointF _rectStartWorld;
        private PointF _rectCurrentWorld;

        private bool _draggingItem = false;
        private PointF _dragStartWorld;
        private float _dragStartX, _dragStartY;

        public MainForm()
        {
            Text = "AGV Movement Path Viewer (Nodes + Logs)";
            Width = 1400;
            Height = 850;
            StartPosition = FormStartPosition.CenterScreen;
            KeyPreview = true;

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

            _chkAutoRefresh = new CheckBox { Text = "Auto-refresh", Left = 450, Top = 17, Width = 110 };
            _chkAutoRefresh.CheckedChanged += (s, e) =>
            {
                if (_chkAutoRefresh.Checked) StartWatchers();
                else StopWatchers();
            };
            _top.Controls.Add(_chkAutoRefresh);

            _btnResetView = new Button { Text = "Reset View", Left = 565, Top = 12, Width = 95, Height = 30 };
            _btnResetView.Click += (s, e) => ResetView();
            _top.Controls.Add(_btnResetView);

            _chkShowNodeLabels = new CheckBox { Text = "Show node labels", Left = 670, Top = 17, Width = 140, Checked = true };
            _chkShowNodeLabels.CheckedChanged += (s, e) => Redraw();
            _top.Controls.Add(_chkShowNodeLabels);

            _chkBuilderMode = new CheckBox { Text = "Builder mode", Left = 820, Top = 17, Width = 110 };
            _chkBuilderMode.CheckedChanged += (s, e) =>
            {
                if (!_chkBuilderMode.Checked)
                {
                    _creatingRect = false;
                    _draggingItem = false;
                    _selectedLayoutItem = null;
                    _builderTool = BuilderTool.Select;
                    UpdateBuilderButtons();
                }
                Redraw();
            };
            _top.Controls.Add(_chkBuilderMode);

            _btnToolSelect = new Button { Text = "Select", Left = 930, Top = 12, Width = 70, Height = 30 };
            _btnToolSelect.Click += (s, e) => { _builderTool = BuilderTool.Select; UpdateBuilderButtons(); };
            _top.Controls.Add(_btnToolSelect);

            _btnToolRect = new Button { Text = "Rect", Left = 1005, Top = 12, Width = 60, Height = 30 };
            _btnToolRect.Click += (s, e) => { _builderTool = BuilderTool.Rect; UpdateBuilderButtons(); };
            _top.Controls.Add(_btnToolRect);

            _btnToolText = new Button { Text = "Text", Left = 1070, Top = 12, Width = 60, Height = 30 };
            _btnToolText.Click += (s, e) => { _builderTool = BuilderTool.Text; UpdateBuilderButtons(); };
            _top.Controls.Add(_btnToolText);

            _btnSaveLayout = new Button { Text = "Save Layout", Left = 1135, Top = 12, Width = 95, Height = 30 };
            _btnSaveLayout.Click += (s, e) => SaveLayout();
            _top.Controls.Add(_btnSaveLayout);

            _btnLoadLayout = new Button { Text = "Load Layout", Left = 1235, Top = 12, Width = 95, Height = 30 };
            _btnLoadLayout.Click += (s, e) => LoadLayout();
            _top.Controls.Add(_btnLoadLayout);

            _btnClearLayout = new Button { Text = "Clear Layout", Left = 1335, Top = 12, Width = 95, Height = 30 };
            _btnClearLayout.Click += (s, e) =>
            {
                _layout.Items.Clear();
                _selectedLayoutItem = null;
                Redraw();
            };
            _top.Controls.Add(_btnClearLayout);

            _lblStatus = new Label { Text = "Load nodes + logs to start.", Left = 10, Top = 60, AutoSize = true, Visible = false };
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

            this.KeyDown += MainForm_KeyDown;
            UpdateBuilderButtons();
        }

        private void MainForm_KeyDown(object sender, KeyEventArgs e)
        {
            if (!_chkBuilderMode.Checked) return;

            if (e.KeyCode == Keys.Delete && _selectedLayoutItem != null)
            {
                _layout.Items.Remove(_selectedLayoutItem);
                _selectedLayoutItem = null;
                Redraw();
            }

            if (e.Control && e.KeyCode == Keys.S)
            {
                SaveLayout();
            }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            StopWatchers();
            base.OnFormClosed(e);
        }

        private void UpdateBuilderButtons()
        {
            bool bm = _chkBuilderMode.Checked;
            _btnToolSelect.Enabled = bm;
            _btnToolRect.Enabled = bm;
            _btnToolText.Enabled = bm;
            _btnSaveLayout.Enabled = bm;
            _btnLoadLayout.Enabled = bm;
            _btnClearLayout.Enabled = bm;

            _btnToolSelect.BackColor = (_builderTool == BuilderTool.Select && bm) ? SystemColors.ActiveCaption : SystemColors.Control;
            _btnToolRect.BackColor = (_builderTool == BuilderTool.Rect && bm) ? SystemColors.ActiveCaption : SystemColors.Control;
            _btnToolText.BackColor = (_builderTool == BuilderTool.Text && bm) ? SystemColors.ActiveCaption : SystemColors.Control;
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
            _canvas.Focus();

            if (_chkBuilderMode.Checked)
            {
                if (e.Button == MouseButtons.Left)
                {
                    var w = ScreenToWorld(e.Location, _zoom, _panPx);

                    if (_builderTool == BuilderTool.Rect)
                    {
                        _creatingRect = true;
                        _rectStartWorld = w;
                        _rectCurrentWorld = w;
                        Redraw();
                        return;
                    }

                    if (_builderTool == BuilderTool.Text)
                    {
                        string txt = InputBox.Show(this, "Text", "Enter text:");
                        if (!string.IsNullOrEmpty(txt))
                        {
                            var item = new LayoutItem
                            {
                                Type = "text",
                                X = w.X,
                                Y = w.Y,
                                W = 0,
                                H = 0,
                                Text = txt
                            };
                            _layout.Items.Add(item);
                            _selectedLayoutItem = item;
                            Redraw();
                        }
                        return;
                    }

                    if (_builderTool == BuilderTool.Select)
                    {
                        var hit = HitTestLayoutItem(e.Location);
                        _selectedLayoutItem = hit;

                        if (_selectedLayoutItem != null)
                        {
                            _draggingItem = true;
                            _dragStartWorld = w;
                            _dragStartX = _selectedLayoutItem.X;
                            _dragStartY = _selectedLayoutItem.Y;
                        }

                        Redraw();
                        return;
                    }
                }

                if (e.Button == MouseButtons.Right)
                {
                    var hit = HitTestLayoutItem(e.Location);
                    _selectedLayoutItem = hit;
                    Redraw();
                    return;
                }

                if (e.Button == MouseButtons.Middle)
                {
                    _panning = true;
                    _panStartMouse = e.Location;
                    _panStartPanPx = _panPx;
                    _canvas.Cursor = Cursors.Hand;
                    return;
                }

                return;
            }

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
            if (_chkBuilderMode.Checked)
            {
                if (_creatingRect)
                {
                    _rectCurrentWorld = ScreenToWorld(e.Location, _zoom, _panPx);
                    Redraw();
                    return;
                }

                if (_draggingItem && _selectedLayoutItem != null)
                {
                    var w = ScreenToWorld(e.Location, _zoom, _panPx);
                    float dx = w.X - _dragStartWorld.X;
                    float dy = w.Y - _dragStartWorld.Y;
                    _selectedLayoutItem.X = _dragStartX + dx;
                    _selectedLayoutItem.Y = _dragStartY + dy;
                    Redraw();
                    return;
                }

                return;
            }

            if (!_panning) return;

            int dx2 = e.X - _panStartMouse.X;
            int dy2 = e.Y - _panStartMouse.Y;

            _panPx = new PointF(_panStartPanPx.X + dx2, _panStartPanPx.Y + dy2);
            Redraw();
        }

        private void Canvas_MouseUp(object sender, MouseEventArgs e)
        {
            if (_chkBuilderMode.Checked)
            {
                if (e.Button == MouseButtons.Left)
                {
                    if (_creatingRect)
                    {
                        _creatingRect = false;

                        var a = _rectStartWorld;
                        var b = _rectCurrentWorld;

                        float x = Math.Min(a.X, b.X);
                        float y = Math.Min(a.Y, b.Y);
                        float w = Math.Abs(a.X - b.X);
                        float h = Math.Abs(a.Y - b.Y);

                        if (w > 0.0001f && h > 0.0001f)
                        {
                            var item = new LayoutItem
                            {
                                Type = "rect",
                                X = x,
                                Y = y,
                                W = w,
                                H = h,
                                Text = null
                            };
                            _layout.Items.Add(item);
                            _selectedLayoutItem = item;
                        }

                        Redraw();
                        return;
                    }

                    if (_draggingItem)
                    {
                        _draggingItem = false;
                        Redraw();
                        return;
                    }
                }

                if (e.Button == MouseButtons.Middle)
                {
                    if (_panning)
                    {
                        _panning = false;
                        _canvas.Cursor = Cursors.Default;
                        return;
                    }
                }

                return;
            }

            if (_panning && (e.Button == MouseButtons.Middle || e.Button == MouseButtons.Right))
            {
                _panning = false;
                _canvas.Cursor = Cursors.Default;
            }
        }

        private LayoutItem HitTestLayoutItem(Point screenPt)
        {
            for (int i = _layout.Items.Count - 1; i >= 0; i--)
            {
                var it = _layout.Items[i];
                if (it == null) continue;

                if (string.Equals(it.Type, "rect", StringComparison.OrdinalIgnoreCase))
                {
                    var r = WorldRectToScreen(it.X, it.Y, it.W, it.H);
                    if (r.Contains(screenPt)) return it;
                }
                else if (string.Equals(it.Type, "text", StringComparison.OrdinalIgnoreCase))
                {
                    var p = WorldToScreen(new PointF(it.X, it.Y));
                    var box = new RectangleF(p.X - 6, p.Y - 6, 12, 12);
                    if (box.Contains(screenPt)) return it;
                }
            }

            return null;
        }

        private void SaveLayout()
        {
            using (var sfd = new SaveFileDialog())
            {
                sfd.Title = "Save Layout";
                sfd.Filter = "Layout JSON (*.json)|*.json|All files (*.*)|*.*";
                sfd.FileName = "layout.json";
                if (sfd.ShowDialog(this) != DialogResult.OK) return;

                try
                {
                    using (var fs = new FileStream(sfd.FileName, FileMode.Create, FileAccess.Write))
                    {
                        var ser = new DataContractJsonSerializer(typeof(LayoutFile));
                        ser.WriteObject(fs, _layout);
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to save layout:\n\n" + ex.Message, "Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void LoadLayout()
        {
            using (var ofd = new OpenFileDialog())
            {
                ofd.Title = "Load Layout";
                ofd.Filter = "Layout JSON (*.json)|*.json|All files (*.*)|*.*";
                ofd.Multiselect = false;

                if (ofd.ShowDialog(this) != DialogResult.OK) return;

                try
                {
                    LayoutFile loaded;
                    using (var fs = new FileStream(ofd.FileName, FileMode.Open, FileAccess.Read))
                    {
                        var ser = new DataContractJsonSerializer(typeof(LayoutFile));
                        loaded = (LayoutFile)ser.ReadObject(fs);
                    }

                    _layout.Items.Clear();
                    if (loaded != null && loaded.Items != null)
                        _layout.Items.AddRange(loaded.Items);

                    _selectedLayoutItem = null;
                    Redraw();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to load layout:\n\n" + ex.Message, "Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
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

            foreach (var s in _series)
            {
                try
                {
                    if (!File.Exists(s.FilePath)) continue;
                    s.Points = ParseAgvLogCsv_NoDate(s.FilePath, _nodes);
                }
                catch
                {
                }
            }

            ComputeWorldBounds();
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

            var list = new List<AgvPoint>();
            int step = 0;

            for (int r = 1; r < nonEmpty.Length; r++)
            {
                var cols = SplitCsvLine(nonEmpty[r], delim);
                if (cols.Length <= iNode) continue;

                var nodeId = (cols[iNode] ?? "").Trim().Trim('"').Trim();
                if (string.IsNullOrEmpty(nodeId)) continue;

                PointF xy;
                if (!nodes.TryGetValue(nodeId, out xy)) continue;

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
                throw new Exception("0 points parsed from '" + Path.GetFileName(path) + "'. Node IDs likely don't match nodes.csv.");

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
            foreach (var it in _layout.Items)
            {
                if (it == null) continue;
                if (string.Equals(it.Type, "rect", StringComparison.OrdinalIgnoreCase))
                {
                    pts.Add(new PointF(it.X, it.Y));
                    pts.Add(new PointF(it.X + it.W, it.Y + it.H));
                }
                else if (string.Equals(it.Type, "text", StringComparison.OrdinalIgnoreCase))
                {
                    pts.Add(new PointF(it.X, it.Y));
                }
            }

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

            DrawLayout(g);

            DrawNodes(g);

            if (_chkBuilderMode.Checked && _creatingRect)
                DrawPreviewRect(g);

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

                    if (_chkShowNodeLabels.Checked)
                        g.DrawString(kv.Key, font, labelBrush, p.X + 6, p.Y + 3);
                }
            }
        }

        private void DrawLayout(Graphics g)
        {
            if (_layout.Items.Count == 0) return;

            using (var font = new Font("Segoe UI", 10f))
            {
                foreach (var it in _layout.Items)
                {
                    if (it == null) continue;

                    bool selected = ReferenceEquals(it, _selectedLayoutItem);

                    if (string.Equals(it.Type, "rect", StringComparison.OrdinalIgnoreCase))
                    {
                        var r = WorldRectToScreen(it.X, it.Y, it.W, it.H);

                        using (var fill = new SolidBrush(Color.FromArgb(70, 80, 80, 80)))
                            g.FillRectangle(fill, r);

                        using (var pen = new Pen(selected ? Color.Red : Color.FromArgb(120, 60, 60, 60), selected ? 2.5f : 1.5f))
                            g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
                    }
                    else if (string.Equals(it.Type, "text", StringComparison.OrdinalIgnoreCase))
                    {
                        var p = WorldToScreen(new PointF(it.X, it.Y));

                        string txt = it.Text ?? "";
                        var size = g.MeasureString(txt, font);

                        var bg = new RectangleF(p.X, p.Y, size.Width + 10, size.Height + 6);
                        using (var fill = new SolidBrush(Color.FromArgb(90, 255, 255, 255)))
                            g.FillRectangle(fill, bg);

                        using (var pen = new Pen(selected ? Color.Red : Color.FromArgb(140, 0, 0, 0), selected ? 2f : 1f))
                            g.DrawRectangle(pen, bg.X, bg.Y, bg.Width, bg.Height);

                        using (var brush = new SolidBrush(Color.Black))
                            g.DrawString(txt, font, brush, p.X + 5, p.Y + 3);
                    }
                }
            }
        }

        private void DrawPreviewRect(Graphics g)
        {
            var a = _rectStartWorld;
            var b = _rectCurrentWorld;

            float x = Math.Min(a.X, b.X);
            float y = Math.Min(a.Y, b.Y);
            float w = Math.Abs(a.X - b.X);
            float h = Math.Abs(a.Y - b.Y);

            if (w < 0.0001f || h < 0.0001f) return;

            var r = WorldRectToScreen(x, y, w, h);
            using (var pen = new Pen(Color.FromArgb(200, 0, 120, 215), 2f) { DashStyle = DashStyle.Dash })
                g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
        }

        private void DrawSeriesPath(Graphics g, AgvSeries s)
        {
            if (s.Points == null || s.Points.Count == 0) return;

            if (s.Points.Count == 1)
            {
                var only = WorldToScreen(s.Points[0].XY);
                using (var headBrush = new SolidBrush(s.Color))
                    g.FillEllipse(headBrush, only.X - 6, only.Y - 6, 12, 12);
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
                g.FillEllipse(headBrush, last.X - 6, last.Y - 6, 12, 12);
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

            if (_chkBuilderMode.Checked)
            {
                using (var font = new Font("Segoe UI", 9f))
                {
                    string tool = _builderTool.ToString();
                    string hint = "Builder: " + tool + " | Left: use tool | Middle: pan | Delete: remove selected | Ctrl+S: save";
                    g.DrawString(hint, font, Brushes.Black, 10, y + 8);
                }
            }
        }

        private RectangleF WorldRectToScreen(float x, float y, float w, float h)
        {
            var p1 = WorldToScreen(new PointF(x, y));
            var p2 = WorldToScreen(new PointF(x + w, y + h));
            float left = Math.Min(p1.X, p2.X);
            float top = Math.Min(p1.Y, p2.Y);
            float right = Math.Max(p1.X, p2.X);
            float bottom = Math.Max(p1.Y, p2.Y);
            return new RectangleF(left, top, right - left, bottom - top);
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

        public static class InputBox
        {
            public static string Show(IWin32Window owner, string title, string prompt)
            {
                using (var f = new Form())
                using (var lbl = new Label())
                using (var tb = new TextBox())
                using (var ok = new Button())
                using (var cancel = new Button())
                {
                    f.Text = title;
                    f.FormBorderStyle = FormBorderStyle.FixedDialog;
                    f.StartPosition = FormStartPosition.CenterParent;
                    f.MinimizeBox = false;
                    f.MaximizeBox = false;
                    f.ShowInTaskbar = false;
                    f.ClientSize = new Size(420, 140);

                    lbl.Text = prompt;
                    lbl.Left = 10;
                    lbl.Top = 12;
                    lbl.Width = 400;

                    tb.Left = 10;
                    tb.Top = 40;
                    tb.Width = 400;

                    ok.Text = "OK";
                    ok.Left = 250;
                    ok.Top = 80;
                    ok.Width = 75;
                    ok.DialogResult = DialogResult.OK;

                    cancel.Text = "Cancel";
                    cancel.Left = 335;
                    cancel.Top = 80;
                    cancel.Width = 75;
                    cancel.DialogResult = DialogResult.Cancel;

                    f.Controls.Add(lbl);
                    f.Controls.Add(tb);
                    f.Controls.Add(ok);
                    f.Controls.Add(cancel);

                    f.AcceptButton = ok;
                    f.CancelButton = cancel;

                    var dr = f.ShowDialog(owner);
                    if (dr == DialogResult.OK) return tb.Text;
                    return null;
                }
            }
        }
    }
}
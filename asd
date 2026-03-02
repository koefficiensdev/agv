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
        private readonly CheckBox _chkShowNodeLabels;

        private readonly CheckBox _chkWifiHeatmap;
        private readonly ComboBox _cmbAp;

        private readonly CheckBox _chkBuilderMode;
        private readonly Button _btnToolSelect;
        private readonly Button _btnToolRect;
        private readonly Button _btnToolText;
        private readonly Button _btnSaveLayout;
        private readonly Button _btnLoadLayout;
        private readonly Button _btnClearLayout;

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

        private readonly List<LayoutItem> _layoutItems = new List<LayoutItem>();
        private LayoutItem _selectedLayoutItem = null;

        private enum BuilderTool { Select, Rect, Text }
        private BuilderTool _builderTool = BuilderTool.Select;

        private bool _creatingRect = false;
        private PointF _rectStartWorld;
        private PointF _rectCurrentWorld;

        private bool _draggingItem = false;
        private PointF _dragStartWorld;
        private float _dragStartX, _dragStartY;

        private bool _spaceDown = false;

        public MainForm()
        {
            Text = "AGV Movement Path Viewer (Nodes + Logs)";
            Width = 1600;
            Height = 900;
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
                RefreshApList();
                ComputeWorldBounds();
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

            _chkWifiHeatmap = new CheckBox { Text = "WiFi heatmap", Left = 820, Top = 17, Width = 110, Checked = false };
            _chkWifiHeatmap.CheckedChanged += (s, e) =>
            {
                _cmbAp.Enabled = _chkWifiHeatmap.Checked;
                Redraw();
            };
            _top.Controls.Add(_chkWifiHeatmap);

            _cmbAp = new ComboBox { Left = 935, Top = 14, Width = 210, DropDownStyle = ComboBoxStyle.DropDownList, Enabled = false };
            _cmbAp.SelectedIndexChanged += (s, e) => Redraw();
            _top.Controls.Add(_cmbAp);

            _chkBuilderMode = new CheckBox { Text = "Builder mode", Left = 1155, Top = 17, Width = 110 };
            _chkBuilderMode.CheckedChanged += (s, e) =>
            {
                if (!_chkBuilderMode.Checked)
                {
                    _creatingRect = false;
                    _draggingItem = false;
                    _selectedLayoutItem = null;
                    _builderTool = BuilderTool.Select;
                    _panning = false;
                    _canvas.Cursor = Cursors.Default;
                }
                UpdateBuilderButtons();
                Redraw();
            };
            _top.Controls.Add(_chkBuilderMode);

            _btnToolSelect = new Button { Text = "Select", Left = 1265, Top = 12, Width = 70, Height = 30 };
            _btnToolSelect.Click += (s, e) => { _builderTool = BuilderTool.Select; UpdateBuilderButtons(); };
            _top.Controls.Add(_btnToolSelect);

            _btnToolRect = new Button { Text = "Rect", Left = 1340, Top = 12, Width = 60, Height = 30 };
            _btnToolRect.Click += (s, e) => { _builderTool = BuilderTool.Rect; UpdateBuilderButtons(); };
            _top.Controls.Add(_btnToolRect);

            _btnToolText = new Button { Text = "Text", Left = 1405, Top = 12, Width = 60, Height = 30 };
            _btnToolText.Click += (s, e) => { _builderTool = BuilderTool.Text; UpdateBuilderButtons(); };
            _top.Controls.Add(_btnToolText);

            _btnSaveLayout = new Button { Text = "Save Layout", Left = 1470, Top = 12, Width = 95, Height = 30 };
            _btnSaveLayout.Click += (s, e) => SaveLayout();
            _top.Controls.Add(_btnSaveLayout);

            _btnLoadLayout = new Button { Text = "Load Layout", Left = 1570, Top = 12, Width = 95, Height = 30 };
            _btnLoadLayout.Click += (s, e) => LoadLayout();
            _top.Controls.Add(_btnLoadLayout);

            _btnClearLayout = new Button { Text = "Clear Layout", Left = 1670, Top = 12, Width = 95, Height = 30 };
            _btnClearLayout.Click += (s, e) =>
            {
                _layoutItems.Clear();
                _selectedLayoutItem = null;
                ComputeWorldBounds();
                Redraw();
            };
            _top.Controls.Add(_btnClearLayout);

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
            this.KeyUp += MainForm_KeyUp;

            UpdateBuilderButtons();
            RefreshApList();
        }

        private void MainForm_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space) _spaceDown = true;

            if (_chkBuilderMode.Checked)
            {
                if (e.KeyCode == Keys.Delete && _selectedLayoutItem != null)
                {
                    _layoutItems.Remove(_selectedLayoutItem);
                    _selectedLayoutItem = null;
                    ComputeWorldBounds();
                    Redraw();
                }

                if (e.Control && e.KeyCode == Keys.S)
                    SaveLayout();
            }
        }

        private void MainForm_KeyUp(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space) _spaceDown = false;
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

            if (_chkBuilderMode.Checked && _spaceDown && e.Button == MouseButtons.Left)
            {
                _panning = true;
                _panStartMouse = e.Location;
                _panStartPanPx = _panPx;
                _canvas.Cursor = Cursors.Hand;
                return;
            }

            if (_chkBuilderMode.Checked)
            {
                if (e.Button == MouseButtons.Middle)
                {
                    _panning = true;
                    _panStartMouse = e.Location;
                    _panStartPanPx = _panPx;
                    _canvas.Cursor = Cursors.Hand;
                    return;
                }

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
                            _layoutItems.Add(item);
                            _selectedLayoutItem = item;
                            ComputeWorldBounds();
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
                    _selectedLayoutItem = HitTestLayoutItem(e.Location);
                    Redraw();
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
                if (_panning)
                {
                    int dx = e.X - _panStartMouse.X;
                    int dy = e.Y - _panStartMouse.Y;
                    _panPx = new PointF(_panStartPanPx.X + dx, _panStartPanPx.Y + dy);
                    Redraw();
                    return;
                }

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
                    ComputeWorldBounds();
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
                if (_panning && ((_spaceDown && e.Button == MouseButtons.Left) || e.Button == MouseButtons.Middle))
                {
                    _panning = false;
                    _canvas.Cursor = Cursors.Default;
                    return;
                }

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
                            _layoutItems.Add(item);
                            _selectedLayoutItem = item;
                            ComputeWorldBounds();
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
            for (int i = _layoutItems.Count - 1; i >= 0; i--)
            {
                var it = _layoutItems[i];
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
                sfd.Filter = "Layout (*.layout)|*.layout|All files (*.*)|*.*";
                sfd.FileName = "layout.layout";
                if (sfd.ShowDialog(this) != DialogResult.OK) return;

                try
                {
                    using (var sw = new StreamWriter(sfd.FileName, false, Encoding.UTF8))
                    {
                        sw.WriteLine("LAYOUT1");
                        foreach (var it in _layoutItems)
                        {
                            string type = (it.Type ?? "").Trim().ToLowerInvariant();
                            string x = it.X.ToString("R", CultureInfo.InvariantCulture);
                            string y = it.Y.ToString("R", CultureInfo.InvariantCulture);
                            string w = it.W.ToString("R", CultureInfo.InvariantCulture);
                            string h = it.H.ToString("R", CultureInfo.InvariantCulture);
                            string text = EscapeText(it.Text ?? "");
                            sw.WriteLine(type + "|" + x + "|" + y + "|" + w + "|" + h + "|" + text);
                        }
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to save layout:\n\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void LoadLayout()
        {
            using (var ofd = new OpenFileDialog())
            {
                ofd.Title = "Load Layout";
                ofd.Filter = "Layout (*.layout)|*.layout|All files (*.*)|*.*";
                ofd.Multiselect = false;

                if (ofd.ShowDialog(this) != DialogResult.OK) return;

                try
                {
                    var items = new List<LayoutItem>();

                    using (var sr = new StreamReader(ofd.FileName, Encoding.UTF8, true))
                    {
                        string header = sr.ReadLine();
                        if (header == null || header.Trim() != "LAYOUT1")
                            throw new Exception("Invalid layout file.");

                        string line;
                        while ((line = sr.ReadLine()) != null)
                        {
                            if (string.IsNullOrWhiteSpace(line)) continue;
                            var parts = line.Split(new[] { '|' }, 6);
                            if (parts.Length < 6) continue;

                            string type = (parts[0] ?? "").Trim().ToLowerInvariant();

                            float x = ParseFloatInvariant(parts[1]);
                            float y = ParseFloatInvariant(parts[2]);
                            float w = ParseFloatInvariant(parts[3]);
                            float h = ParseFloatInvariant(parts[4]);
                            string text = UnescapeText(parts[5]);

                            if (type != "rect" && type != "text") continue;

                            items.Add(new LayoutItem
                            {
                                Type = type,
                                X = x,
                                Y = y,
                                W = w,
                                H = h,
                                Text = (type == "text") ? text : null
                            });
                        }
                    }

                    _layoutItems.Clear();
                    _layoutItems.AddRange(items);
                    _selectedLayoutItem = null;
                    ComputeWorldBounds();
                    Redraw();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to load layout:\n\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private static string EscapeText(string s)
        {
            if (s == null) return "";
            return s.Replace("\\", "\\\\")
                    .Replace("\r", "\\r")
                    .Replace("\n", "\\n")
                    .Replace("\t", "\\t")
                    .Replace("|", "\\p");
        }

        private static string UnescapeText(string s)
        {
            if (s == null) return "";
            var sb = new StringBuilder();
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '\\' && i + 1 < s.Length)
                {
                    char n = s[i + 1];
                    if (n == '\\') { sb.Append('\\'); i++; continue; }
                    if (n == 'r') { sb.Append('\r'); i++; continue; }
                    if (n == 'n') { sb.Append('\n'); i++; continue; }
                    if (n == 't') { sb.Append('\t'); i++; continue; }
                    if (n == 'p') { sb.Append('|'); i++; continue; }
                }
                sb.Append(c);
            }
            return sb.ToString();
        }

        private static float ParseFloatInvariant(string s)
        {
            s = (s ?? "").Trim();
            float v;
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
            s = s.Replace(',', '.');
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
            return 0f;
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
                    MessageBox.Show(this, "Failed to load nodes CSV:\n\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
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

                        List<WifiSample> wifi;
                        var points = ParseAgvLogCsv_NoDate(file, _nodes, out wifi);

                        _series.Add(new AgvSeries
                        {
                            Name = agvName,
                            FilePath = file,
                            Points = points,
                            Wifi = wifi
                        });
                    }

                    AssignColors();
                    RefreshApList();
                    ComputeWorldBounds();
                    ResetView();
                    Redraw();

                    if (_chkAutoRefresh.Checked) StartWatchers();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Failed to load AGV log CSV(s):\n\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
                    List<WifiSample> wifi;
                    s.Points = ParseAgvLogCsv_NoDate(s.FilePath, _nodes, out wifi);
                    s.Wifi = wifi;
                }
                catch
                {
                }
            }

            RefreshApList();
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

        private static bool TryParseSignal0to100(string raw, out int sig)
        {
            sig = 0;
            if (raw == null) return false;

            string s = raw.Trim().Trim('"').Trim();
            if (s.Length == 0) return false;

            s = s.Replace("%", "").Trim();

            int si;
            if (int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out si) ||
                int.TryParse(s, NumberStyles.Integer, CultureInfo.CurrentCulture, out si))
            {
                if (si < 0) si = 0;
                if (si > 100) si = 100;
                sig = si;
                return true;
            }

            float sf;
            if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out sf) ||
                float.TryParse(s.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out sf) ||
                float.TryParse(s, NumberStyles.Float, CultureInfo.CurrentCulture, out sf))
            {
                int v = (int)Math.Round(sf);
                if (v < 0) v = 0;
                if (v > 100) v = 100;
                sig = v;
                return true;
            }

            return false;
        }

        private static List<AgvPoint> ParseAgvLogCsv_NoDate(string path, Dictionary<string, PointF> nodes, out List<WifiSample> wifiSamples)
        {
            wifiSamples = new List<WifiSample>();

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

            int iSig = FindCol(header, "wifisig", "wifi_sig", "wifisignal", "wifi_signal", "wifi", "signal", "sig", "rssi");
            int iMac = FindCol(header, "wifimac", "wifi_mac", "bssid", "ap", "apmac", "mac");

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

                if (iSig >= 0 && iMac >= 0 && cols.Length > Math.Max(iSig, iMac))
                {
                    var mac = (cols[iMac] ?? "").Trim().Trim('"').Trim();
                    var sigStr = cols[iSig];
                    int sig;
                    if (!string.IsNullOrEmpty(mac) && TryParseSignal0to100(sigStr, out sig))
                        wifiSamples.Add(new WifiSample { Mac = mac, Signal = sig, NodeId = nodeId, XY = xy });
                }
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
            foreach (var s in _series) pts.AddRange(s.Points.Select(p => p.XY));
            foreach (var it in _layoutItems)
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

        private void RefreshApList()
        {
            var allMacs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var s in _series)
            {
                if (s.Wifi == null) continue;
                foreach (var w in s.Wifi)
                {
                    if (!string.IsNullOrWhiteSpace(w.Mac))
                        allMacs.Add(w.Mac.Trim());
                }
            }

            var selected = _cmbAp.SelectedItem as string;

            _cmbAp.Items.Clear();
            _cmbAp.Items.Add("ALL");
            foreach (var mac in allMacs.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                _cmbAp.Items.Add(mac);

            if (selected != null && _cmbAp.Items.Contains(selected))
                _cmbAp.SelectedItem = selected;
            else
                _cmbAp.SelectedIndex = 0;
        }

        private int TotalWifiSamples()
        {
            int n = 0;
            for (int i = 0; i < _series.Count; i++)
            {
                if (_series[i].Wifi != null) n += _series[i].Wifi.Count;
            }
            return n;
        }

        private int TotalAps()
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < _series.Count; i++)
            {
                var w = _series[i].Wifi;
                if (w == null) continue;
                for (int j = 0; j < w.Count; j++)
                {
                    var m = (w[j].Mac ?? "").Trim();
                    if (m.Length > 0) set.Add(m);
                }
            }
            return set.Count;
        }

        private void Canvas_Paint(object sender, PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.White);

            DrawGrid(g);

            if (_chkWifiHeatmap.Checked)
                DrawWifiHeatmap(g);

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

        private void DrawWifiHeatmap(Graphics g)
        {
            if (_nodes.Count == 0) return;

            string selected = (_cmbAp.SelectedItem as string) ?? "ALL";
            bool all = string.Equals(selected, "ALL", StringComparison.OrdinalIgnoreCase);

            var perApPerNode = new Dictionary<string, Dictionary<string, SigAgg>>(StringComparer.OrdinalIgnoreCase);

            for (int si = 0; si < _series.Count; si++)
            {
                var s = _series[si];
                var wifi = s.Wifi;
                if (wifi == null || wifi.Count == 0) continue;

                for (int i = 0; i < wifi.Count; i++)
                {
                    var w = wifi[i];
                    if (string.IsNullOrWhiteSpace(w.Mac)) continue;
                    if (!all && !string.Equals(w.Mac, selected, StringComparison.OrdinalIgnoreCase)) continue;

                    Dictionary<string, SigAgg> perNode;
                    if (!perApPerNode.TryGetValue(w.Mac, out perNode))
                    {
                        perNode = new Dictionary<string, SigAgg>(StringComparer.OrdinalIgnoreCase);
                        perApPerNode[w.Mac] = perNode;
                    }

                    SigAgg agg;
                    if (!perNode.TryGetValue(w.NodeId, out agg))
                        agg = new SigAgg();

                    agg.Sum += w.Signal;
                    agg.Count += 1;
                    perNode[w.NodeId] = agg;
                }
            }

            if (perApPerNode.Count == 0) return;

            int radius = 30;

            foreach (var kvAp in perApPerNode)
            {
                foreach (var kvNode in kvAp.Value)
                {
                    PointF xy;
                    if (!_nodes.TryGetValue(kvNode.Key, out xy)) continue;

                    float avg = (kvNode.Value.Count <= 0) ? 0f : (float)kvNode.Value.Sum / kvNode.Value.Count;
                    int sig = (int)Math.Round(avg);
                    if (sig < 0) sig = 0;
                    if (sig > 100) sig = 100;

                    int alpha = 60 + (int)Math.Round(sig * 1.4);
                    if (alpha < 60) alpha = 60;
                    if (alpha > 210) alpha = 210;

                    var col = SignalToColor(sig, alpha);
                    var p = WorldToScreen(xy);

                    using (var b = new SolidBrush(col))
                        g.FillEllipse(b, p.X - radius, p.Y - radius, radius * 2, radius * 2);
                }
            }
        }

        private static Color SignalToColor(int sig, int alpha)
        {
            if (sig < 0) sig = 0;
            if (sig > 100) sig = 100;

            if (sig <= 50)
            {
                float t = sig / 50f;
                int r = 255;
                int g = (int)Math.Round(0 + 255 * t);
                int b = 0;
                return Color.FromArgb(alpha, r, g, b);
            }
            else
            {
                float t = (sig - 50) / 50f;
                int r = (int)Math.Round(255 - 255 * t);
                int g = 255;
                int b = 0;
                return Color.FromArgb(alpha, r, g, b);
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
            if (_layoutItems.Count == 0) return;

            using (var font = new Font("Segoe UI", 10f))
            {
                foreach (var it in _layoutItems)
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

            using (var font = new Font("Segoe UI", 9f))
            {
                if (_chkWifiHeatmap.Checked)
                {
                    string sel = (_cmbAp.SelectedItem as string) ?? "ALL";
                    g.DrawString("WiFi heatmap: " + sel + " | APs: " + TotalAps() + " | Samples: " + TotalWifiSamples(), font, Brushes.Black, 10, y + 8);
                }
                else
                {
                    g.DrawString("WiFi samples: " + TotalWifiSamples() + " | APs: " + TotalAps(), font, Brushes.Black, 10, y + 8);
                }
            }

            if (_chkBuilderMode.Checked)
            {
                using (var font = new Font("Segoe UI", 9f))
                {
                    string tool = _builderTool.ToString();
                    string hint = "Builder: " + tool + " | Space+Left: pan | Middle: pan | Delete: remove | Ctrl+S: save";
                    g.DrawString(hint, font, Brushes.Black, 10, y + 28);
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

        private void Redraw()
        {
            _canvas.Invalidate();
        }

        private sealed class AgvPoint
        {
            public int Step;
            public string NodeId;
            public PointF XY;
        }

        private sealed class WifiSample
        {
            public string Mac;
            public int Signal;
            public string NodeId;
            public PointF XY;
        }

        private struct SigAgg
        {
            public int Sum;
            public int Count;
        }

        private sealed class AgvSeries
        {
            public string Name;
            public string FilePath;
            public List<AgvPoint> Points = new List<AgvPoint>();
            public List<WifiSample> Wifi = new List<WifiSample>();
            public Color Color = Color.Blue;
        }

        private sealed class LayoutItem
        {
            public string Type;
            public float X;
            public float Y;
            public float W;
            public float H;
            public string Text;
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
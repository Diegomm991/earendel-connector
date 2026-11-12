using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Printing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace EarendelXPrintBridge
{
    static class Program
    {
        private static NotifyIcon _trayIcon;
        private static HttpListener _listener;
        private static Thread _serverThread;
        private static bool _isRunning = true;
        private const int Port = 17864;
        private const string AppName = "EarendelX Print Bridge";

        [STAThread]
        static void Main()
        {
            using (var mutex = new Mutex(true, "EarendelXPrintBridgeMutex_v1", out bool createdNew))
            {
                if (!createdNew)
                {
                    MessageBox.Show(
                        "EarendelX Print Bridge ya se está ejecutando en segundo plano.\nRevisa el icono junto al reloj de Windows.",
                        AppName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information
                    );
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                // Configurar inicio automático con Windows
                RegisterStartup(true);

                // Iniciar servidor local
                StartServer();

                // Configurar icono de bandeja
                SetupTray();

                // Notificación inicial
                _trayIcon.ShowBalloonTip(
                    3000,
                    AppName,
                    "Conector activo. Listo para imprimir tickets desde earendelx.com",
                    ToolTipIcon.Info
                );

                Application.Run();

                _isRunning = false;
                try { _listener?.Stop(); } catch { }
            }
        }

        private static void SetupTray()
        {
            var menu = new ContextMenuStrip();

            var titleItem = new ToolStripMenuItem("🟢 EarendelX Print Bridge (Activo)") { Enabled = false };
            var portItem = new ToolStripMenuItem($"Puerto: {Port}") { Enabled = false };
            menu.Items.Add(titleItem);
            menu.Items.Add(portItem);
            menu.Items.Add(new ToolStripSeparator());

            var openWebItem = new ToolStripMenuItem("Abrir EarendelX Web", null, (s, e) =>
            {
                try { System.Diagnostics.Process.Start("https://earendelx.com"); } catch { }
            });
            menu.Items.Add(openWebItem);

            var autoStartItem = new ToolStripMenuItem("Iniciar con Windows") { Checked = IsStartupRegistered() };
            autoStartItem.Click += (s, e) =>
            {
                bool newState = !autoStartItem.Checked;
                RegisterStartup(newState);
                autoStartItem.Checked = newState;
            };
            menu.Items.Add(autoStartItem);

            menu.Items.Add(new ToolStripSeparator());

            var exitItem = new ToolStripMenuItem("Salir", null, (s, e) =>
            {
                _trayIcon.Visible = false;
                Application.Exit();
            });
            menu.Items.Add(exitItem);

            _trayIcon = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                ContextMenuStrip = menu,
                Text = "EarendelX Print Bridge (Activo)",
                Visible = true
            };
        }

        private static void StartServer()
        {
            _serverThread = new Thread(() =>
            {
                try
                {
                    _listener = new HttpListener();
                    _listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
                    _listener.Prefixes.Add($"http://localhost:{Port}/");
                    _listener.Start();

                    while (_isRunning && _listener.IsListening)
                    {
                        try
                        {
                            var ctx = _listener.GetContext();
                            ThreadPool.QueueUserWorkItem((state) => HandleRequest(ctx));
                        }
                        catch (HttpListenerException)
                        {
                            break;
                        }
                        catch { }
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show(
                        $"No se pudo iniciar el servicio en el puerto {Port}: {ex.Message}",
                        AppName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error
                    );
                }
            })
            {
                IsBackground = true
            };
            _serverThread.Start();
        }

        private static void HandleRequest(HttpListenerContext ctx)
        {
            var req = ctx.Request;
            var res = ctx.Response;

            // CORS y Private Network Access para Chrome/Edge
            res.Headers.Add("Access-Control-Allow-Origin", "*");
            res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
            res.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization");
            res.Headers.Add("Access-Control-Allow-Private-Network", "true");
            res.Headers.Add("Cache-Control", "no-store");

            if (req.HttpMethod == "OPTIONS")
            {
                res.StatusCode = 204;
                res.Close();
                return;
            }

            try
            {
                string path = req.Url.AbsolutePath.ToLowerInvariant();

                if (path == "/health")
                {
                    SendJson(res, 200, "{\"ready\":true,\"platform\":\"windows\",\"name\":\"EarendelX Print Bridge\",\"version\":\"1.0.0\",\"raw\":true}");
                    return;
                }

                if (path == "/pair")
                {
                    SendJson(res, 200, "{\"ready\":true,\"token\":\"local-bridge\",\"platform\":\"windows\",\"raw\":true}");
                    return;
                }

                if (path == "/printers" && req.HttpMethod == "GET")
                {
                    var sb = new StringBuilder();
                    sb.Append("{\"ready\":true,\"raw\":true,\"printers\":[");
                    bool first = true;
                    foreach (string printer in PrinterSettings.InstalledPrinters)
                    {
                        if (!first) sb.Append(",");
                        first = false;
                        sb.Append("{\"name\":\"").Append(EscapeJson(printer)).Append("\",\"url\":\"").Append(EscapeJson(printer)).Append("\"}");
                    }
                    sb.Append("]}");
                    SendJson(res, 200, sb.ToString());
                    return;
                }

                if (path == "/print" && req.HttpMethod == "POST")
                {
                    using (var reader = new StreamReader(req.InputStream, req.ContentEncoding))
                    {
                        string body = reader.ReadToEnd();
                        string printerName = ExtractJsonValue(body, "printer");
                        string format = ExtractJsonValue(body, "format");
                        string base64Data = ExtractJsonValue(body, "data");

                        if (string.IsNullOrEmpty(printerName) || string.IsNullOrEmpty(base64Data))
                        {
                            SendJson(res, 400, "{\"error\":\"Datos de impresion incompletos\"}");
                            return;
                        }

                        byte[] bytes = Convert.FromBase64String(base64Data);
                        bool ok = RawPrinterHelper.SendBytesToPrinter(printerName, bytes);

                        if (ok)
                        {
                            SendJson(res, 200, "{\"printed\":true}");
                        }
                        else
                        {
                            SendJson(res, 500, "{\"error\":\"No se pudo enviar el trabajo a la impresora Windows Spooler\"}");
                        }
                        return;
                    }
                }

                SendJson(res, 404, "{\"error\":\"Ruta no encontrada\"}");
            }
            catch (Exception ex)
            {
                SendJson(res, 500, $"{{\"error\":\"{EscapeJson(ex.Message)}\"}}");
            }
        }

        private static void SendJson(HttpListenerResponse res, int statusCode, string json)
        {
            byte[] buffer = Encoding.UTF8.GetBytes(json);
            res.StatusCode = statusCode;
            res.ContentType = "application/json; charset=utf-8";
            res.ContentLength64 = buffer.Length;
            res.OutputStream.Write(buffer, 0, buffer.Length);
            res.Close();
        }

        private static string EscapeJson(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "");
        }

        private static string ExtractJsonValue(string json, string key)
        {
            string pattern = "\"" + key + "\"";
            int idx = json.IndexOf(pattern, StringComparison.OrdinalIgnoreCase);
            if (idx == -1) return "";
            int colonIdx = json.IndexOf(':', idx + pattern.Length);
            if (colonIdx == -1) return "";
            int startQuote = json.IndexOf('"', colonIdx + 1);
            if (startQuote == -1) return "";
            int endQuote = json.IndexOf('"', startQuote + 1);
            while (endQuote != -1 && json[endQuote - 1] == '\\')
            {
                endQuote = json.IndexOf('"', endQuote + 1);
            }
            if (endQuote == -1) return "";
            return json.Substring(startQuote + 1, endQuote - startQuote - 1);
        }

        private static bool IsStartupRegistered()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false))
                {
                    return key?.GetValue("EarendelXPrintBridge") != null;
                }
            }
            catch { return false; }
        }

        private static void RegisterStartup(bool enable)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key == null) return;
                    if (enable)
                    {
                        key.SetValue("EarendelXPrintBridge", $"\"{Application.ExecutablePath}\"");
                    }
                    else
                    {
                        key.DeleteValue("EarendelXPrintBridge", false);
                    }
                }
            }
            catch { }
        }
    }

    public static class RawPrinterHelper
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
        public class DOCINFOA
        {
            [MarshalAs(UnmanagedType.LPStr)]
            public string pDocName;
            [MarshalAs(UnmanagedType.LPStr)]
            public string pOutputFile;
            [MarshalAs(UnmanagedType.LPStr)]
            public string pDataType;
        }

        [DllImport("winspool.Drv", EntryPoint = "OpenPrinterA", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool OpenPrinter([MarshalAs(UnmanagedType.LPStr)] string szPrinter, out IntPtr hPrinter, IntPtr pd);

        [DllImport("winspool.Drv", EntryPoint = "ClosePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool ClosePrinter(IntPtr hPrinter);

        [DllImport("winspool.Drv", EntryPoint = "StartDocPrinterA", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFOA di);

        [DllImport("winspool.Drv", EntryPoint = "EndDocPrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool EndDocPrinter(IntPtr hPrinter);

        [DllImport("winspool.Drv", EntryPoint = "StartPagePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool StartPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.Drv", EntryPoint = "EndPagePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool EndPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.Drv", EntryPoint = "WritePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
        public static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, int dwCount, out int dwWritten);

        public static bool SendBytesToPrinter(string szPrinterName, byte[] pBytes)
        {
            IntPtr pUnmanagedBytes = Marshal.AllocCoTaskMem(pBytes.Length);
            Marshal.Copy(pBytes, 0, pUnmanagedBytes, pBytes.Length);
            IntPtr hPrinter;
            var di = new DOCINFOA
            {
                pDocName = "EarendelX POS Ticket",
                pDataType = "RAW"
            };

            bool success = false;
            if (OpenPrinter(szPrinterName, out hPrinter, IntPtr.Zero))
            {
                if (StartDocPrinter(hPrinter, 1, di))
                {
                    if (StartPagePrinter(hPrinter))
                    {
                        success = WritePrinter(hPrinter, pUnmanagedBytes, pBytes.Length, out _);
                        EndPagePrinter(hPrinter);
                    }
                    EndDocPrinter(hPrinter);
                }
                ClosePrinter(hPrinter);
            }
            Marshal.FreeCoTaskMem(pUnmanagedBytes);
            return success;
        }
    }
}

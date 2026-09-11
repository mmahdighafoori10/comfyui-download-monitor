using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("ComfyUI Download Monitor")]
[assembly: AssemblyDescription("Windows launcher for the ComfyUI download manager")]
[assembly: AssemblyCompany("ComfyUI Download Monitor")]
[assembly: AssemblyProduct("ComfyUI Download Monitor")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace ComfyUIDownloadMonitor
{
    internal static class Launcher
    {
        private const string MonitorScriptName = "ComfyDownloadMonitor.ps1";
        private const string WatcherScriptName = "ComfyDownloadWatcher.ps1";
        private const string ResumeWorkerScriptName = "ComfyResumeWorker.ps1";
        private const string SelfTestReportName = "ComfyUIDownloadMonitor-SelfTest.txt";

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                string applicationDirectory = AppDomain.CurrentDomain.BaseDirectory;
                if (HasArgument(args, "--self-test"))
                {
                    return RunSelfTest(applicationDirectory);
                }

                if (HasArgument(args, "--watcher"))
                {
                    StartPowerShellScript(applicationDirectory, WatcherScriptName, false, string.Empty);
                    return 0;
                }

                StartPowerShellScript(applicationDirectory, WatcherScriptName, false, string.Empty);
                StartPowerShellScript(applicationDirectory, MonitorScriptName, true, string.Empty);
                return 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "اجرای برنامه ممکن نشد.\r\n\r\n" + exception.Message,
                    "ComfyUI Download Monitor",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error,
                    MessageBoxDefaultButton.Button1,
                    MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
                return 1;
            }
        }

        private static bool HasArgument(string[] args, string expected)
        {
            foreach (string argument in args)
            {
                if (string.Equals(argument, expected, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static string GetWindowsPowerShellPath()
        {
            string powerShellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");

            if (!File.Exists(powerShellPath))
            {
                throw new FileNotFoundException("Windows PowerShell پیدا نشد.", powerShellPath);
            }

            return powerShellPath;
        }

        private static void StartPowerShellScript(
            string applicationDirectory,
            string scriptName,
            bool requiresSta,
            string additionalArguments)
        {
            string scriptPath = Path.Combine(applicationDirectory, scriptName);
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("فایل لازم برنامه پیدا نشد.", scriptPath);
            }

            string arguments = string.Format(
                "-NoProfile {0}-ExecutionPolicy Bypass {1}-File {2} {3}",
                requiresSta ? "-STA " : string.Empty,
                requiresSta ? string.Empty : "-WindowStyle Hidden ",
                QuoteArgument(scriptPath),
                additionalArguments).Trim();

            ProcessStartInfo processInfo = new ProcessStartInfo
            {
                FileName = GetWindowsPowerShellPath(),
                Arguments = arguments,
                WorkingDirectory = applicationDirectory,
                UseShellExecute = !requiresSta,
                CreateNoWindow = requiresSta,
                WindowStyle = requiresSta ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(processInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("پردازش برنامه ایجاد نشد.");
                }
            }
        }

        private static int RunSelfTest(string applicationDirectory)
        {
            StringBuilder report = new StringBuilder();
            int monitorExitCode = RunPowerShellSelfTest(
                Path.Combine(applicationDirectory, MonitorScriptName),
                true,
                string.Empty,
                report);
            int watcherExitCode = RunPowerShellSelfTest(
                Path.Combine(applicationDirectory, WatcherScriptName),
                false,
                string.Empty,
                report);

            string resumeWorkerPath = Path.Combine(applicationDirectory, ResumeWorkerScriptName);
            report.AppendLine("=== " + ResumeWorkerScriptName + " ===");
            report.AppendLine(File.Exists(resumeWorkerPath) ? "PRESENT" : "MISSING");
            report.AppendLine();

            string reportPath = Path.Combine(Path.GetTempPath(), SelfTestReportName);
            File.WriteAllText(reportPath, report.ToString(), new UTF8Encoding(false));
            return monitorExitCode == 0 && watcherExitCode == 0 && File.Exists(resumeWorkerPath) ? 0 : 1;
        }

        private static int RunPowerShellSelfTest(
            string scriptPath,
            bool requiresSta,
            string additionalArguments,
            StringBuilder report)
        {
            if (!File.Exists(scriptPath))
            {
                report.AppendLine("MISSING: " + scriptPath);
                return 1;
            }

            ProcessStartInfo processInfo = new ProcessStartInfo
            {
                FileName = GetWindowsPowerShellPath(),
                Arguments = string.Format(
                    "-NoProfile {0}-ExecutionPolicy Bypass -File {1} -SelfTest {2}",
                    requiresSta ? "-STA " : string.Empty,
                    QuoteArgument(scriptPath),
                    additionalArguments).Trim(),
                WorkingDirectory = Path.GetDirectoryName(scriptPath),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(processInfo))
            {
                if (process == null)
                {
                    report.AppendLine("FAILED TO START: " + scriptPath);
                    return 1;
                }

                string standardOutput = process.StandardOutput.ReadToEnd();
                string standardError = process.StandardError.ReadToEnd();
                process.WaitForExit();

                report.AppendLine("=== " + Path.GetFileName(scriptPath) + " ===");
                report.AppendLine(standardOutput.Trim());
                if (!string.IsNullOrWhiteSpace(standardError))
                {
                    report.AppendLine("ERROR:");
                    report.AppendLine(standardError.Trim());
                }
                report.AppendLine("EXIT CODE: " + process.ExitCode);
                report.AppendLine();
                return process.ExitCode;
            }
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}

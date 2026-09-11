using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("ComfyUI Download Monitor Setup")]
[assembly: AssemblyDescription("Installer for ComfyUI Download Monitor")]
[assembly: AssemblyCompany("ComfyUI Download Monitor")]
[assembly: AssemblyProduct("ComfyUI Download Monitor")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace ComfyUIDownloadMonitorSetup
{
    internal static class SetupProgram
    {
        private const string ProductName = "ComfyUI Download Monitor";
        private const string ProductVersion = "1.0.0";
        private const string LauncherFileName = "ComfyUIDownloadMonitor.exe";
        private const string UninstallerFileName = "Uninstall.exe";
        private const string InstallReceiptFileName = "install-state.txt";
        private const string SetupLogFileName = "ComfyUIDownloadMonitor-Setup.log";
        private const string UninstallRegistryKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ComfyUIDownloadMonitor";
        private const string ResourcePrefix = "ComfyUIDownloadMonitor.Resources.";

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool isSilent = HasArgument(args, "--silent");
            bool isUninstall = HasArgument(args, "--uninstall");

            try
            {
                if (isUninstall)
                {
                    if (!isSilent && MessageBox.Show(
                        "برنامه ComfyUI Download Monitor حذف شود؟",
                        "حذف برنامه",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question,
                        MessageBoxDefaultButton.Button2,
                        MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign) != DialogResult.Yes)
                    {
                        return 0;
                    }

                    Uninstall(isSilent);
                    return 0;
                }

                Install(isSilent);
                return 0;
            }
            catch (Exception exception)
            {
                WriteSetupLog(exception.ToString());
                if (!isSilent)
                {
                    MessageBox.Show(
                        "عملیات انجام نشد.\r\n\r\n" + exception.Message,
                        ProductName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error,
                        MessageBoxDefaultButton.Button1,
                        MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
                }

                return 1;
            }
        }

        private static void Install(bool isSilent)
        {
            string installDirectory = GetInstallDirectory();
            Directory.CreateDirectory(installDirectory);
            StopInstalledPowerShellProcesses(installDirectory);

            ExtractResource(ResourcePrefix + "LauncherExe", Path.Combine(installDirectory, LauncherFileName));
            ExtractResource(ResourcePrefix + "MonitorScript", Path.Combine(installDirectory, "ComfyDownloadMonitor.ps1"));
            ExtractResource(ResourcePrefix + "WatcherScript", Path.Combine(installDirectory, "ComfyDownloadWatcher.ps1"));
            ExtractResource(ResourcePrefix + "ResumeWorkerScript", Path.Combine(installDirectory, "ComfyResumeWorker.ps1"));
            ExtractResource(ResourcePrefix + "Readme", Path.Combine(installDirectory, "README.md"));
            CopyInstallerAsUninstaller(Path.Combine(installDirectory, UninstallerFileName));

            string launcherPath = Path.Combine(installDirectory, LauncherFileName);
            string uninstallerPath = Path.Combine(installDirectory, UninstallerFileName);
            string startMenuDirectory = GetStartMenuDirectory();
            Directory.CreateDirectory(startMenuDirectory);

            CreateShortcut(
                Path.Combine(startMenuDirectory, ProductName + ".lnk"),
                launcherPath,
                string.Empty,
                installDirectory,
                "مدیریت دانلود مدل‌های ComfyUI");
            CreateShortcut(
                Path.Combine(startMenuDirectory, "Uninstall " + ProductName + ".lnk"),
                uninstallerPath,
                "--uninstall",
                installDirectory,
                "حذف " + ProductName);
            CreateShortcut(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), ProductName + ".lnk"),
                launcherPath,
                string.Empty,
                installDirectory,
                "مدیریت دانلود مدل‌های ComfyUI");
            CreateShortcut(
                GetStartupShortcutPath(),
                launcherPath,
                "--watcher",
                installDirectory,
                "باز کردن خودکار مدیر دانلود هنگام شروع دانلود ComfyUI");

            bool registeredInWindowsApps = TryRegisterUninstaller(installDirectory, launcherPath, uninstallerPath);
            WriteInstallReceipt(installDirectory, registeredInWindowsApps);
            StartLauncher(launcherPath, installDirectory, "--watcher");

            if (!isSilent)
            {
                MessageBox.Show(
                    "نصب انجام شد. میان‌بر برنامه روی Desktop و Start Menu ساخته شد.",
                    ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information,
                    MessageBoxDefaultButton.Button1,
                    MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
                StartLauncher(launcherPath, installDirectory, string.Empty);
            }
        }

        private static void Uninstall(bool isSilent)
        {
            string installDirectory = GetInstallDirectory();
            StopInstalledPowerShellProcesses(installDirectory);

            DeleteFileIfPresent(Path.Combine(GetStartMenuDirectory(), ProductName + ".lnk"));
            DeleteFileIfPresent(Path.Combine(GetStartMenuDirectory(), "Uninstall " + ProductName + ".lnk"));
            DeleteFileIfPresent(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), ProductName + ".lnk"));
            DeleteFileIfPresent(GetStartupShortcutPath());

            string startMenuDirectory = GetStartMenuDirectory();
            if (Directory.Exists(startMenuDirectory) && Directory.GetFileSystemEntries(startMenuDirectory).Length == 0)
            {
                Directory.Delete(startMenuDirectory);
            }

            try
            {
                Registry.CurrentUser.DeleteSubKeyTree(UninstallRegistryKey, false);
            }
            catch (UnauthorizedAccessException)
            {
                // The shortcuts and application files can still be removed.
            }
            catch (System.Security.SecurityException)
            {
                // Same as above in a restricted host.
            }
            ScheduleInstallDirectoryRemoval(installDirectory);

            if (!isSilent)
            {
                MessageBox.Show(
                    "برنامه حذف شد.",
                    ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information,
                    MessageBoxDefaultButton.Button1,
                    MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
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

        private static string GetInstallDirectory()
        {
            string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string programsDirectory = Path.GetFullPath(Path.Combine(localApplicationData, "Programs"));
            string installDirectory = Path.GetFullPath(Path.Combine(programsDirectory, ProductName));
            string expectedPrefix = programsDirectory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;

            if (!installDirectory.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("مسیر نصب معتبر نیست.");
            }

            return installDirectory;
        }

        private static string GetStartMenuDirectory()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), ProductName);
        }

        private static string GetStartupShortcutPath()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Startup),
                ProductName + " Watcher.lnk");
        }

        private static void ExtractResource(string resourceName, string destinationPath)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resourceStream = assembly.GetManifestResourceStream(resourceName))
            {
                if (resourceStream == null)
                {
                    throw new InvalidOperationException("منبع نصب پیدا نشد: " + resourceName);
                }

                using (FileStream destinationStream = new FileStream(
                    destinationPath,
                    FileMode.Create,
                    FileAccess.Write,
                    FileShare.None))
                {
                    resourceStream.CopyTo(destinationStream);
                }
            }
        }

        private static void CopyInstallerAsUninstaller(string uninstallerPath)
        {
            string currentExecutable = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
            string destination = Path.GetFullPath(uninstallerPath);
            if (string.Equals(currentExecutable, destination, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            File.Copy(currentExecutable, destination, true);
        }

        private static void CreateShortcut(
            string shortcutPath,
            string targetPath,
            string arguments,
            string workingDirectory,
            string description)
        {
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null)
            {
                throw new InvalidOperationException("سرویس ساخت میان‌بر ویندوز در دسترس نیست.");
            }

            object shell = null;
            object shortcut = null;
            try
            {
                shell = Activator.CreateInstance(shellType);
                shortcut = shellType.InvokeMember(
                    "CreateShortcut",
                    BindingFlags.InvokeMethod,
                    null,
                    shell,
                    new object[] { shortcutPath });

                Type shortcutType = shortcut.GetType();
                shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { targetPath });
                shortcutType.InvokeMember("Arguments", BindingFlags.SetProperty, null, shortcut, new object[] { arguments });
                shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { workingDirectory });
                shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { description });
                shortcutType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { targetPath + ",0" });
                shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            }
            finally
            {
                if (shortcut != null && Marshal.IsComObject(shortcut))
                {
                    Marshal.FinalReleaseComObject(shortcut);
                }
                if (shell != null && Marshal.IsComObject(shell))
                {
                    Marshal.FinalReleaseComObject(shell);
                }
            }
        }

        private static bool TryRegisterUninstaller(string installDirectory, string launcherPath, string uninstallerPath)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(UninstallRegistryKey))
                {
                    if (key == null)
                    {
                        return false;
                    }

                    key.SetValue("DisplayName", ProductName);
                    key.SetValue("DisplayVersion", ProductVersion);
                    key.SetValue("Publisher", ProductName);
                    key.SetValue("InstallLocation", installDirectory);
                    key.SetValue("DisplayIcon", launcherPath + ",0");
                    key.SetValue("UninstallString", "\"" + uninstallerPath + "\" --uninstall");
                    key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
                return true;
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
            catch (System.Security.SecurityException)
            {
                return false;
            }
        }

        private static void StartLauncher(string launcherPath, string installDirectory, string arguments)
        {
            ProcessStartInfo processInfo = new ProcessStartInfo
            {
                FileName = launcherPath,
                Arguments = arguments,
                WorkingDirectory = installDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(processInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("اجرای برنامه پس از نصب ممکن نشد.");
                }
            }
        }

        private static void WriteInstallReceipt(string installDirectory, bool registeredInWindowsApps)
        {
            string[] lines =
            {
                "Product=" + ProductName,
                "Version=" + ProductVersion,
                "InstalledAtUtc=" + DateTime.UtcNow.ToString("o"),
                "InstallDirectory=" + installDirectory,
                "WindowsAppsRegistration=" + registeredInWindowsApps.ToString()
            };
            File.WriteAllLines(
                Path.Combine(installDirectory, InstallReceiptFileName),
                lines,
                new System.Text.UTF8Encoding(false));
        }

        private static void WriteSetupLog(string message)
        {
            try
            {
                string logPath = Path.Combine(Path.GetTempPath(), SetupLogFileName);
                File.WriteAllText(
                    logPath,
                    DateTime.UtcNow.ToString("o") + Environment.NewLine + message,
                    new System.Text.UTF8Encoding(false));
            }
            catch
            {
                // The original setup error is more useful than a secondary logging error.
            }
        }

        private static void StopInstalledPowerShellProcesses(string installDirectory)
        {
            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'"))
                using (ManagementObjectCollection processes = searcher.Get())
                {
                    foreach (ManagementObject process in processes)
                    {
                        using (process)
                        {
                            string commandLine = Convert.ToString(process["CommandLine"]);
                            if (commandLine.IndexOf(installDirectory, StringComparison.OrdinalIgnoreCase) < 0)
                            {
                                continue;
                            }
                            if (commandLine.IndexOf("ComfyDownloadMonitor.ps1", StringComparison.OrdinalIgnoreCase) < 0 &&
                                commandLine.IndexOf("ComfyDownloadWatcher.ps1", StringComparison.OrdinalIgnoreCase) < 0 &&
                                commandLine.IndexOf("ComfyResumeWorker.ps1", StringComparison.OrdinalIgnoreCase) < 0)
                            {
                                continue;
                            }

                            process.InvokeMethod("Terminate", null);
                        }
                    }
                }
            }
            catch (ManagementException)
            {
                // Uninstallation can continue; the delayed cleanup retries after exit.
            }
            catch (UnauthorizedAccessException)
            {
                // Same as above for restricted user sessions.
            }
        }

        private static void ScheduleInstallDirectoryRemoval(string installDirectory)
        {
            string currentExecutable = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
            if (!currentExecutable.StartsWith(installDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                if (Directory.Exists(installDirectory))
                {
                    Directory.Delete(installDirectory, true);
                }
                return;
            }

            string escapedPath = installDirectory.Replace("'", "''");
            string cleanupCommand = "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '" + escapedPath + "' -Recurse -Force";
            ProcessStartInfo cleanupInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    "System32",
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + cleanupCommand + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process cleanupProcess = Process.Start(cleanupInfo))
            {
                if (cleanupProcess == null)
                {
                    throw new InvalidOperationException("پاک‌سازی فایل‌های برنامه زمان‌بندی نشد.");
                }
            }
        }

        private static void DeleteFileIfPresent(string path)
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }
}

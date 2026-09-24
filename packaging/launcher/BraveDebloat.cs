// BraveDebloat.exe: a tiny native launcher for Invoke-BraveDebloat.ps1.
//
// winget's community repository only accepts .exe files as portable commands, so the Windows
// release zip ships this launcher next to the script. It runs the PowerShell script that sits in
// its own folder with the arguments it was given and returns the script's exit code. It writes
// nothing itself; every Brave change still goes through Invoke-BraveDebloat.ps1 and its dry-run
// default. Built by scripts/Build-Launcher.ps1 with the C# compiler that ships in .NET Framework,
// so keep this file C# 5 compatible (no string interpolation, ?. or expression-bodied members).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace BraveDebloater
{
    internal static class Launcher
    {
        private const string ScriptName = "Invoke-BraveDebloat.ps1";

        private static int Main(string[] args)
        {
            try
            {
                string launcherPath = ResolveFinalPath(GetLauncherPath());
                string scriptPath = Path.Combine(Path.GetDirectoryName(launcherPath), ScriptName);
                if (!File.Exists(scriptPath))
                {
                    Console.Error.WriteLine("BraveDebloat: " + ScriptName + " was not found next to the launcher at " + scriptPath);
                    Console.Error.WriteLine("Keep BraveDebloat.exe inside the extracted BraveDebloater folder, or run the script directly.");
                    return 2;
                }

                string shell = FindPowerShell();
                if (shell == null)
                {
                    Console.Error.WriteLine("BraveDebloat: neither pwsh.exe nor powershell.exe was found. Install PowerShell 7 or run " + ScriptName + " from Windows PowerShell.");
                    return 2;
                }

                bool ownsConsole = OwnsConsole();
                ProcessStartInfo startInfo = new ProcessStartInfo(shell, BuildArguments(scriptPath, args));
                startInfo.UseShellExecute = false;
                startInfo.WorkingDirectory = Path.GetDirectoryName(scriptPath);
                // Tells the script to quote printed commands for cmd.exe, where this launcher usually runs.
                startInfo.EnvironmentVariables["BRAVEDEBLOATER_LAUNCHER"] = "1";

                int exitCode;
                using (Process process = Process.Start(startInfo))
                {
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                }

                if (ownsConsole)
                {
                    // Started from Explorer: keep the window open so the output can be read.
                    Console.WriteLine();
                    Console.Write("Press Enter to close this window.");
                    Console.ReadLine();
                }

                return exitCode;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("BraveDebloat launcher failed: " + ex.Message);
                return 1;
            }
        }

        private static string GetLauncherPath()
        {
            string location = typeof(Launcher).Assembly.Location;
            if (!string.IsNullOrEmpty(location))
            {
                return location;
            }
            return Process.GetCurrentProcess().MainModule.FileName;
        }

        private static bool IsWindows()
        {
            return Environment.OSVersion.Platform == PlatformID.Win32NT;
        }

        private static string FindPowerShell()
        {
            List<string> names = new List<string>();
            names.Add("pwsh.exe");
            if (!IsWindows())
            {
                names.Add("pwsh");
            }

            foreach (string name in names)
            {
                string found = FindOnPath(name);
                if (found != null)
                {
                    return found;
                }
            }

            if (IsWindows())
            {
                string systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
                if (!string.IsNullOrEmpty(systemRoot))
                {
                    string windowsPowerShell = Path.Combine(systemRoot, @"System32\WindowsPowerShell\v1.0\powershell.exe");
                    if (File.Exists(windowsPowerShell))
                    {
                        return windowsPowerShell;
                    }
                }
                return FindOnPath("powershell.exe");
            }

            return null;
        }

        private static string FindOnPath(string fileName)
        {
            string pathVariable = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (string entry in pathVariable.Split(Path.PathSeparator))
            {
                string directory = entry.Trim().Trim('"');
                if (directory.Length == 0)
                {
                    continue;
                }
                try
                {
                    string candidate = Path.Combine(directory, fileName);
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
                catch (ArgumentException)
                {
                    // Skip PATH entries with characters Path.Combine rejects.
                }
            }
            return null;
        }

        private static string BuildArguments(string scriptPath, string[] args)
        {
            StringBuilder builder = new StringBuilder();
            builder.Append("-NoProfile -ExecutionPolicy Bypass -File ");
            builder.Append(Quote(scriptPath));
            foreach (string arg in args)
            {
                builder.Append(' ');
                builder.Append(Quote(arg));
            }
            return builder.ToString();
        }

        private static string Quote(string value)
        {
            // Follows the CommandLineToArgvW rules so PowerShell sees each argument unchanged.
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return value;
            }

            StringBuilder builder = new StringBuilder();
            builder.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    builder.Append('\\', backslashes * 2 + 1);
                    builder.Append('"');
                    backslashes = 0;
                    continue;
                }
                builder.Append('\\', backslashes);
                builder.Append(character);
                backslashes = 0;
            }
            builder.Append('\\', backslashes * 2);
            builder.Append('"');
            return builder.ToString();
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetConsoleProcessList(uint[] processList, uint processCount);

        private static string ResolveFinalPath(string path)
        {
            // When the exe runs through a symlink (for example winget's Links folder), the process
            // path points at the link, so the script must be looked up next to the real file.
            if (!IsWindows())
            {
                return path;
            }
            try
            {
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    StringBuilder buffer = new StringBuilder(4096);
                    uint length = GetFinalPathNameByHandle(stream.SafeFileHandle, buffer, (uint)buffer.Capacity, 0);
                    if (length == 0 || length >= buffer.Capacity)
                    {
                        return path;
                    }
                    string resolved = buffer.ToString();
                    if (resolved.StartsWith(@"\\?\UNC\", StringComparison.Ordinal))
                    {
                        return @"\\" + resolved.Substring(8);
                    }
                    if (resolved.StartsWith(@"\\?\", StringComparison.Ordinal))
                    {
                        return resolved.Substring(4);
                    }
                    return resolved;
                }
            }
            catch (Exception)
            {
                return path;
            }
        }

        private static bool OwnsConsole()
        {
            if (!IsWindows() || Console.IsInputRedirected || !Environment.UserInteractive)
            {
                return false;
            }
            try
            {
                uint[] processes = new uint[2];
                return GetConsoleProcessList(processes, (uint)processes.Length) == 1;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}

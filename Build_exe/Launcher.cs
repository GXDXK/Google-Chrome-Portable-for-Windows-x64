// Chrome 便携版更新器启动器（WinExe，无控制台窗口）
// 将 ChromePlusUpdater.ps1 作为内嵌资源，运行时解出到临时目录，
// 以隐藏方式启动 PowerShell（SW_HIDE，不出现终端窗口），并传入 exe 所在目录作为基目录。
// 编译：运行 build_exe.bat（使用系统自带的 .NET Framework csc.exe，无需安装任何东西）
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static int Main()
    {
        try
        {
            // 读取内嵌的 ps1 脚本
            string content;
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("ChromePlusUpdater.ps1"))
            {
                if (s == null)
                {
                    MessageBox.Show("内嵌脚本资源缺失：ChromePlusUpdater.ps1", "Chrome 便携版更新器",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }
                using (StreamReader r = new StreamReader(s, Encoding.UTF8))
                {
                    content = r.ReadToEnd();
                }
            }

            // 解出到临时目录（带 BOM 的 UTF-8，确保中文正常）
            string ps1 = Path.Combine(Path.GetTempPath(),
                "ChromePlusUpdater_" + Guid.NewGuid().ToString("N") + ".ps1");
            File.WriteAllText(ps1, content, new UTF8Encoding(true));

            // 以隐藏方式启动 PowerShell；基目录优先指向项目根目录
            // （exe 位于 Build_exe\ 子目录且上级存在 ChromePlusUpdater.ps1 时，用上级目录；
            //   否则用 exe 所在目录，保持“复制到任意位置即可用”的便携行为）
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string baseDir = exeDir;
            string parentDir = Path.GetFullPath(Path.Combine(exeDir, ".."));
            if (File.Exists(Path.Combine(parentDir, "ChromePlusUpdater.ps1")))
            {
                baseDir = parentDir;
            }
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" + ps1 + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.EnvironmentVariables["CPUP_BASE_DIR"] = baseDir;

            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
            }
            try { File.Delete(ps1); } catch { }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动失败：" + ex.Message, "Chrome 便携版更新器",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

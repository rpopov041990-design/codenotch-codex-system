using System.Runtime.InteropServices;

namespace Codenotch.Windows;

public record Metric(string Name, double? Percent, string Detail);

public sealed class Sensors
{
    [StructLayout(LayoutKind.Sequential)]
    struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PowerStatus
    {
        public byte AC, Flag, Percent, Saver;
        public uint Life, FullLife;
    }
    [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSystemPowerStatus(out PowerStatus status);
    ulong lastIdle, lastTotal;
    bool primed;

    public List<Metric> Read()
    {
        var output = new List<Metric>();
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (GlobalMemoryStatusEx(ref memory) && memory.TotalPhysical > 0)
        {
            double used = memory.TotalPhysical - memory.AvailablePhysical;
            output.Add(new("RAM", used / memory.TotalPhysical * 100,
                $"Занято {used / 1073741824:0.0} из {memory.TotalPhysical / 1073741824.0:0.0} ГБ физической памяти"));
        }
        else output.Add(new("RAM", null, "Память: нет данных"));
        double? cpu = null;
        if (GetSystemTimes(out var idle, out var kernel, out var user))
        {
            ulong total = kernel + user;
            if (primed && total > lastTotal && idle >= lastIdle)
                cpu = Math.Clamp(100.0 * (1 - (double)(idle - lastIdle) / (total - lastTotal)), 0, 100);
            lastIdle = idle; lastTotal = total; primed = true;
        }
        output.Add(new("CPU", cpu, cpu is null ? "CPU: ждём второй замер" : "Загрузка между двумя замерами; на системах >64 CPU — группа процессоров текущего процесса"));
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))!);
            long total = drive.TotalSize, free = drive.TotalFreeSpace;
            output.Add(new("Диск", total > 0 ? 100.0 * (total - free) / total : null,
                $"Том {drive.Name}: свободно {free / 1073741824.0:0.0} из {total / 1073741824.0:0.0} ГБ"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        { output.Add(new("Диск", null, "Диск: нет данных")); }
        if (GetSystemPowerStatus(out var power))
        {
            if (power.Flag != 255 && (power.Flag & 128) != 0) { /* Desktop without battery: omit. */ }
            else
            {
                string state = power.Flag == 255 ? "Состояние неизвестно" : (power.Flag & 8) != 0 ? "Заряжается" : power.AC == 1 ? "Питание от сети" : power.AC == 0 ? "Питание от батареи" : "Источник неизвестен";
                output.Add(new("АКБ", power.Percent <= 100 ? power.Percent : null, state + ". Износ и здоровье АКБ: недоступны в этой версии."));
            }
        }
        else output.Add(new("АКБ", null, "Батарея: нет данных"));
        output.Add(new("Нагрев", null, "Температура и тепловое состояние: недоступны без подходящего аппаратного источника. Драйверы не устанавливаются."));
        return output;
    }
}

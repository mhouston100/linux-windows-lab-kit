using System.Text;
using DiscUtils.Registry;

if (args.Length == 1 && args[0] == "--self-test")
{
    return SelfTest();
}

if (args.Length != 1)
{
    Console.Error.WriteLine("usage: HiveSet HIVE < records");
    return 2;
}

using (var stream = File.Open(args[0], FileMode.Open, FileAccess.ReadWrite, FileShare.None))
using (var hive = new RegistryHive(stream))
{
    var input = Console.OpenStandardInput();
    while (true)
    {
        var key = ReadField(input, out var eof, out var truncated);
        if (eof)
        {
            break;
        }
        var name = ReadField(input, out _, out var nameTruncated);
        var type = ReadField(input, out _, out var typeTruncated);
        var data = ReadField(input, out _, out var dataTruncated);
        if (truncated || nameTruncated || typeTruncated || dataTruncated || name == null || type == null || data == null)
        {
            Console.Error.WriteLine("truncated registry record");
            return 1;
        }

        var node = hive.Root.CreateSubKey(key);
        if (node == null)
        {
            Console.Error.WriteLine("cannot create registry key");
            return 1;
        }
        if (type == "sz")
        {
            node.SetValue(name, data, RegistryValueType.String);
        }
        else if (type == "dword")
        {
            if (!uint.TryParse(data, out var dword))
            {
                Console.Error.WriteLine("registry dword is not a number");
                return 1;
            }
            node.SetValue(name, dword, RegistryValueType.Dword);
        }
        else
        {
            Console.Error.WriteLine("unknown registry type");
            return 1;
        }
    }
    stream.Flush();
}

return 0;

static int SelfTest()
{
    var path = Path.Combine(Path.GetTempPath(), "lab-hive-set-test.hive");
    File.Delete(path);
    using (var stream = File.Create(path))
    using (var hive = RegistryHive.Create(stream))
    {
        hive.Root.CreateSubKey(@"Microsoft\Windows\CurrentVersion\RunOnce")!
            .SetValue("VBoxGuestAdditions", "one", RegistryValueType.String);
        hive.Root.CreateSubKey(@"Microsoft\Windows\CurrentVersion\RunOnce")!
            .SetValue("Other", "keep-me", RegistryValueType.String);
        var winlogon = hive.Root.CreateSubKey(@"Microsoft\Windows NT\CurrentVersion\Winlogon")!;
        winlogon.SetValue("AutoAdminLogon", "1", RegistryValueType.String);
        winlogon.SetValue("AutoLogonCount", 1u, RegistryValueType.Dword);
        stream.Flush();
    }

    using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
    using (var hive = new RegistryHive(stream))
    {
        var run = hive.Root.OpenSubKey(@"Microsoft\Windows\CurrentVersion\RunOnce");
        var win = hive.Root.OpenSubKey(@"Microsoft\Windows NT\CurrentVersion\Winlogon");
        if (run?.GetValue("VBoxGuestAdditions") as string != "one"
            || run.GetValue("Other") as string != "keep-me"
            || win?.GetValue("AutoAdminLogon") as string != "1"
            || win.GetValue("AutoLogonCount") is not uint count
            || count != 1)
        {
            Console.Error.WriteLine("hive self-test failed");
            return 1;
        }
    }

    File.Delete(path);
    Console.WriteLine("hive self-test ok");
    return 0;
}

static string? ReadField(Stream input, out bool eof, out bool truncated)
{
    eof = false;
    truncated = false;
    var bytes = new List<byte>();
    int c = input.ReadByte();
    if (c < 0)
    {
        eof = true;
        return null;
    }
    while (c >= 0 && c != 0)
    {
        bytes.Add((byte)c);
        c = input.ReadByte();
    }
    if (c < 0)
    {
        truncated = true;
    }
    return Encoding.UTF8.GetString(bytes.ToArray());
}

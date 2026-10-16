using System.Reflection;
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
    var code = Apply(hive, Console.OpenStandardInput());
    if (code != 0)
    {
        return code;
    }
    stream.Flush();
}

return 0;

static int Apply(RegistryHive hive, Stream input)
{
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

        // A missing key would update a Windows security descriptor, and that
        // API does not exist on Linux. The lab keys are already in the hive.
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
            node.SetValue(name, unchecked((int)dword), RegistryValueType.Dword);
        }
        else
        {
            Console.Error.WriteLine("unknown registry type");
            return 1;
        }
    }
    return 0;
}

static bool IsDword(object? value, int expected)
{
    return value is int number && number == expected
        || value is uint unsigned && unsigned == (uint)expected;
}

static void WriteField(Stream output, string value)
{
    var bytes = Encoding.UTF8.GetBytes(value);
    output.Write(bytes);
    output.WriteByte(0);
}

// RegistryHive.Create builds a Windows ACL, which Linux rejects. The plant
// opens an existing hive, so the self-test builds that empty hive without an ACL.
static RegistryHive CreateEmptyHive(Stream stream)
{
    const BindingFlags inst = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    var asm = typeof(RegistryHive).Assembly;
    var binHeaderType = asm.GetType("DiscUtils.Registry.BinHeader")!;
    var hiveHeaderType = asm.GetType("DiscUtils.Registry.HiveHeader")!;
    var keyNodeType = asm.GetType("DiscUtils.Registry.KeyNodeCell")!;
    var flagsType = asm.GetType("DiscUtils.Registry.RegistryKeyFlags")!;

    var binHeader = Activator.CreateInstance(binHeaderType)!;
    binHeaderType.GetField("FileOffset")!.SetValue(binHeader, 0);
    binHeaderType.GetField("BinSize")!.SetValue(binHeader, 4 * 1024);
    var hiveHeader = Activator.CreateInstance(hiveHeaderType)!;
    hiveHeaderType.GetField("Length")!.SetValue(hiveHeader, 4 * 1024);

    var hiveSize = (int)hiveHeaderType.GetProperty("Size")!.GetValue(hiveHeader)!;
    var buffer = new byte[hiveSize];
    hiveHeaderType.GetMethod("WriteTo")!.Invoke(hiveHeader, new object[] { buffer, 0 });
    stream.Position = 0;
    stream.Write(buffer, 0, buffer.Length);

    var binHeaderSize = (int)binHeaderType.GetProperty("Size")!.GetValue(binHeader)!;
    buffer = new byte[binHeaderSize];
    binHeaderType.GetMethod("WriteTo")!.Invoke(binHeader, new object[] { buffer, 0 });
    stream.Position = 4 * 1024;
    stream.Write(buffer, 0, buffer.Length);
    buffer = new byte[4];
    BitConverter.TryWriteBytes(buffer, (int)binHeaderType.GetField("BinSize")!.GetValue(binHeader)! - binHeaderSize);
    stream.Write(buffer, 0, buffer.Length);
    stream.Position = 8 * 1024 - 1;
    stream.WriteByte(0);

    var hive = new RegistryHive(stream);
    var root = Activator.CreateInstance(keyNodeType, "root", -1)!;
    var flags = Convert.ToInt32(Enum.Parse(flagsType, "Normal")) | Convert.ToInt32(Enum.Parse(flagsType, "Root"));
    keyNodeType.GetField("Flags")!.SetValue(root, Enum.ToObject(flagsType, flags));
    typeof(RegistryHive).GetMethod("UpdateCell", inst)!.Invoke(hive, new object[] { root, true });
    hiveHeaderType.GetField("RootCell")!.SetValue(hiveHeader, (int)keyNodeType.GetProperty("Index")!.GetValue(root)!);

    buffer = new byte[hiveSize];
    hiveHeaderType.GetMethod("WriteTo")!.Invoke(hiveHeader, new object[] { buffer, 0 });
    stream.Position = 0;
    stream.Write(buffer, 0, buffer.Length);
    var liveHeader = typeof(RegistryHive).GetField("_header", inst)!.GetValue(hive)!;
    hiveHeaderType.GetField("RootCell")!.SetValue(liveHeader, hiveHeaderType.GetField("RootCell")!.GetValue(hiveHeader));
    return hive;
}

static RegistryKey AddKey(RegistryKey parent, string name)
{
    const BindingFlags inst = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    var keyType = typeof(RegistryKey);
    var cell = keyType.GetField("_cell", inst)!.GetValue(parent)!;
    var hive = (RegistryHive)keyType.GetField("_hive", inst)!.GetValue(parent)!;
    var parentIndex = (int)cell.GetType().GetProperty("Index")!.GetValue(cell)!;
    var keyNodeType = typeof(RegistryHive).Assembly.GetType("DiscUtils.Registry.KeyNodeCell")!;
    var child = Activator.CreateInstance(keyNodeType, name, parentIndex)!;
    typeof(RegistryHive).GetMethod("UpdateCell", inst)!.Invoke(hive, new object[] { child, true });
    var index = (int)keyNodeType.GetProperty("Index")!.GetValue(child)!;
    keyType.GetMethod("LinkSubKey", inst)!.Invoke(parent, new object[] { name, index });
    return (RegistryKey)Activator.CreateInstance(keyType, inst, binder: null, new object[] { hive, child }, culture: null)!;
}

static RegistryKey EnsurePath(RegistryHive hive, string path)
{
    var key = hive.Root;
    foreach (var part in path.Split('\\'))
    {
        key = key.OpenSubKey(part) ?? AddKey(key, part);
    }
    return key;
}

static int SelfTest()
{
    var path = Path.Combine(Path.GetTempPath(), "lab-hive-set-test.hive");
    File.Delete(path);
    using (var stream = File.Create(path))
    using (var hive = CreateEmptyHive(stream))
    {
        EnsurePath(hive, @"Microsoft\Windows\CurrentVersion\RunOnce")
            .SetValue("Other", "keep-me", RegistryValueType.String);
        EnsurePath(hive, @"Microsoft\Windows NT\CurrentVersion\Winlogon");
        stream.Flush();
    }

    var payload = new MemoryStream();
    WriteField(payload, @"Microsoft\Windows\CurrentVersion\RunOnce");
    WriteField(payload, "VBoxGuestAdditions");
    WriteField(payload, "sz");
    WriteField(payload, @"powershell.exe -File C:\Windows\Temp\vbox-ga\install-guest-additions.ps1");
    WriteField(payload, @"Microsoft\Windows NT\CurrentVersion\Winlogon");
    WriteField(payload, "AutoAdminLogon");
    WriteField(payload, "sz");
    WriteField(payload, "1");
    WriteField(payload, @"Microsoft\Windows NT\CurrentVersion\Winlogon");
    WriteField(payload, "DefaultUserName");
    WriteField(payload, "sz");
    WriteField(payload, "LabAdmin");
    WriteField(payload, @"Microsoft\Windows NT\CurrentVersion\Winlogon");
    WriteField(payload, "AutoLogonCount");
    WriteField(payload, "dword");
    WriteField(payload, "1");
    payload.Position = 0;

    using (var stream = File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
    using (var hive = new RegistryHive(stream))
    {
        if (Apply(hive, payload) != 0)
        {
            return 1;
        }
        stream.Flush();
    }

    using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
    using (var hive = new RegistryHive(stream))
    {
        var run = hive.Root.OpenSubKey(@"Microsoft\Windows\CurrentVersion\RunOnce");
        var win = hive.Root.OpenSubKey(@"Microsoft\Windows NT\CurrentVersion\Winlogon");
        var command = run?.GetValue("VBoxGuestAdditions") as string;
        if (run?.GetValue("Other") as string != "keep-me"
            || command == null
            || !command.Contains("install-guest-additions.ps1", StringComparison.Ordinal)
            || win?.GetValue("AutoAdminLogon") as string != "1"
            || win.GetValue("DefaultUserName") as string != "LabAdmin"
            || !IsDword(win.GetValue("AutoLogonCount"), 1))
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

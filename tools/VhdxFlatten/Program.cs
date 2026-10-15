using System.Globalization;
using DiscUtils;
using DiscUtils.Streams;
using DiscUtils.Vhdx;

static int Usage()
{
    Console.Error.WriteLine(
        """
        Usage:
          VhdxFlatten <child.vhdx> <output.vhdx> [--parent <parent.vhdx>]

        Flattens a Hyper-V differencing VHDX (unsupported by qemu-img) into a
        standalone dynamic VHDX that qemu-img / VirtualBox can convert.
        """);
    return 2;
}

if (args.Length < 2)
{
    return Usage();
}

string childPath = Path.GetFullPath(args[0]);
string outputPath = Path.GetFullPath(args[1]);
string? parentOverride = null;

for (int i = 2; i < args.Length; i++)
{
    if (args[i] is "--parent" && i + 1 < args.Length)
    {
        parentOverride = Path.GetFullPath(args[++i]);
    }
    else
    {
        return Usage();
    }
}

if (!File.Exists(childPath))
{
    Console.Error.WriteLine($"Child not found: {childPath}");
    return 1;
}

DiscUtils.Setup.SetupHelper.RegisterAssembly(typeof(Disk).Assembly);

Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);

if (parentOverride is not null)
{
    EnsureSiblingParentLink(childPath, parentOverride);
}

Console.WriteLine($"Opening: {childPath}");
using VirtualDisk source = OpenDiskChain(childPath, parentOverride);

long capacity = source.Capacity;
Console.WriteLine($"Virtual size: {FormatBytes(capacity)}");
Console.WriteLine($"Writing dynamic VHDX: {outputPath}");

if (File.Exists(outputPath))
{
    File.Delete(outputPath);
}

using (FileStream outFs = File.Create(outputPath))
using (Disk dest = Disk.InitializeDynamic(outFs, Ownership.None, capacity))
{
    // Sparse-aware copy — do not read the full 512 GiB virtual capacity.
    var pump = new StreamPump(source.Content, dest.Content, 4 * 1024 * 1024)
    {
        SparseCopy = true
    };
    pump.ProgressEvent += (_, e) =>
    {
        if (e.BytesRead % (1L * 1024 * 1024 * 1024) < 4L * 1024 * 1024)
        {
            Console.WriteLine($"  read={FormatBytes(e.BytesRead)} written={FormatBytes(e.BytesWritten)}");
        }
    };
    pump.Run();
    try
    {
        dest.Content.Flush();
    }
    catch (NotImplementedException)
    {
        // Some DiscUtils VHDX content streams do not implement Flush.
    }
}

Console.WriteLine("Done.");
return 0;

static void EnsureSiblingParentLink(string childPath, string parentPath)
{
    string sibling = Path.Combine(Path.GetDirectoryName(childPath)!, Path.GetFileName(parentPath));
    if (File.Exists(sibling))
    {
        return;
    }

    try
    {
        File.CreateSymbolicLink(sibling, parentPath);
        Console.WriteLine($"Linked parent for locator resolution: {sibling} -> {parentPath}");
    }
    catch
    {
        // Same filesystem hardlink is fine too.
        File.Copy(parentPath, sibling);
        Console.WriteLine($"Copied parent beside child: {sibling}");
    }
}

static VirtualDisk OpenDiskChain(string path, string? parentOverride)
{
    try
    {
        return new Disk(path, FileAccess.Read);
    }
    catch (Exception ex) when (parentOverride is not null)
    {
        Console.WriteLine($"Disk(path) failed ({ex.Message}); opening with explicit parent...");
    }

    if (parentOverride is null || !File.Exists(parentOverride))
    {
        throw new InvalidOperationException($"Unable to open {path}; provide --parent.");
    }

    FileStream childStream = File.OpenRead(path);
    FileStream parentStream = File.OpenRead(parentOverride);
    DiskImageFile childLayer = new(childStream, Ownership.Dispose);
    DiskImageFile parentLayer = new(parentStream, Ownership.Dispose);
    // Layer order: child first, absolute parent last (must not NeedsParent).
    return new Disk(new[] { childLayer, parentLayer }, Ownership.Dispose);
}

static string FormatBytes(long n)
{
    string[] units = ["B", "KiB", "MiB", "GiB", "TiB"];
    double v = n;
    int i = 0;
    while (v >= 1024 && i < units.Length - 1)
    {
        v /= 1024;
        i++;
    }

    return string.Create(CultureInfo.InvariantCulture, $"{v:0.##} {units[i]}");
}

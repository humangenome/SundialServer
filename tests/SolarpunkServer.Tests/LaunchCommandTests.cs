using SolarpunkServer;
using Xunit;

namespace SolarpunkServer.Tests;

public class LaunchCommandTests
{
    [Fact]
    public void ParsesAFullCommandLine()
    {
        var ok = LaunchCommand.TryParse(new[] {
            "--exe", @"C:\g\Game.exe", "--workdir", @"C:\g", "--args", "-nullrhi -log",
            "--dll", @"C:\g\UE4SS.dll", "--optional-dll", @"C:\g\Id.dll", "--affinity", "0x30000" }, out var opt, out var error);
        Assert.True(ok, error);
        Assert.Equal(@"C:\g\Game.exe", opt.Exe);
        Assert.Equal("-nullrhi -log", opt.Args);
        Assert.Equal(new[] { @"C:\g\UE4SS.dll" }, opt.Dlls);
        Assert.Equal(new[] { @"C:\g\Id.dll" }, opt.OptionalDlls);
        Assert.Equal(0x30000UL, opt.Affinity);
    }

    [Fact]
    public void KeepsDllOrder()
    {
        Assert.True(LaunchCommand.TryParse(new[] { "--exe", "a", "--workdir", "b", "--dll", "first", "--dll", "second" }, out var opt, out _));
        Assert.Equal(new[] { "first", "second" }, opt.Dlls);
    }

    [Fact]
    public void ReadsTheGameArgumentsFromAFile()
    {
        var file = Path.GetTempFileName();
        File.WriteAllText(file, "-nullrhi -abslog=\"C:\\a b\\sp-ue.log\" -UserDir=\"C:\\a b\\UserDir\"\r\n");
        try
        {
            Assert.True(LaunchCommand.TryParse(new[] { "--exe", "a", "--workdir", "b", "--args-file", file, "--dll", "x" }, out var opt, out var error), error);
            Assert.Equal("-nullrhi -abslog=\"C:\\a b\\sp-ue.log\" -UserDir=\"C:\\a b\\UserDir\"", opt.Args);
        }
        finally { File.Delete(file); }
    }

    [Theory]
    [InlineData(new[] { "--workdir", "b", "--dll", "x" }, "--exe is required")]
    [InlineData(new[] { "--exe", "a", "--dll", "x" }, "--workdir is required")]
    [InlineData(new[] { "--exe", "a", "--workdir", "b" }, "at least one --dll is required")]
    [InlineData(new[] { "--exe", "a", "--workdir", "b", "--dll" }, "--dll requires a value")]
    [InlineData(new[] { "--exe", "a", "--workdir", "b", "--dll", "x", "--affinity", "zz" }, "--affinity must be a hex mask")]
    [InlineData(new[] { "--exe", "a", "--workdir", "b", "--dll", "x", "--bogus" }, "unknown option --bogus")]
    public void RefusesBadArguments(string[] args, string expected)
    {
        Assert.False(LaunchCommand.TryParse(args, out _, out var error));
        Assert.Equal(expected, error);
    }
}

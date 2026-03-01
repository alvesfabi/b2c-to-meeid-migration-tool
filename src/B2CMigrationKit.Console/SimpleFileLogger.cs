// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Microsoft.Extensions.Logging;

namespace B2CMigrationKit.Console;

/// <summary>
/// Simple file logger provider that writes log entries to a file.
/// No external NuGet packages required.
/// </summary>
public sealed class SimpleFileLoggerProvider : ILoggerProvider
{
    private readonly string _filePath;
    private readonly StreamWriter _writer;
    private readonly object _lock = new();

    public SimpleFileLoggerProvider(string filePath)
    {
        _filePath = filePath;
        _writer = new StreamWriter(filePath, append: true) { AutoFlush = true };
    }

    public ILogger CreateLogger(string categoryName) => new SimpleFileLogger(categoryName, _writer, _lock);

    public void Dispose()
    {
        _writer.Dispose();
    }
}

internal sealed class SimpleFileLogger : ILogger
{
    private readonly string _category;
    private readonly StreamWriter _writer;
    private readonly object _lock;

    public SimpleFileLogger(string category, StreamWriter writer, object lockObj)
    {
        // Shorten category to just the class name
        var lastDot = category.LastIndexOf('.');
        _category = lastDot >= 0 ? category[(lastDot + 1)..] : category;
        _writer = writer;
        _lock = lockObj;
    }

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;

        var level = logLevel switch
        {
            LogLevel.Information => "INFO",
            LogLevel.Warning => "WARN",
            LogLevel.Error => "ERROR",
            LogLevel.Critical => "CRIT",
            _ => logLevel.ToString().ToUpperInvariant()
        };

        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {_category}: {formatter(state, exception)}";

        lock (_lock)
        {
            _writer.WriteLine(line);
            if (exception != null)
            {
                _writer.WriteLine(exception.ToString());
            }
        }
    }
}

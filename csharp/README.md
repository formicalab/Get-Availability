# Get-Availability — C# Version

Native AOT implementation of Get-Availability using .NET 10. Produces a ~15 MB standalone binary with no runtime dependency.

For the full pipeline description, classification rules, output format, and invariants shared with the PowerShell version, see the [main README](../README.md).

## Prerequisites

| Requirement | Detail |
|---|---|
| .NET SDK | 10.0 or later (build from source only) |
| Azure auth | `az login` or any method supported by `DefaultAzureCredential` |

The published binary (`GetAvailability.exe`) requires no .NET runtime — it is a Native AOT self-contained executable.

If Azure authentication fails, the tool prints the SDK exception message directly. Re-run `az login` to fix.

## Parameters

| Option | Short | Default | Description |
|---|---|---|---|
| `--subscriptions` | `-s` | *(required)* | One or more Azure subscription display names |
| `--month` | `-m` | *(required)* | Observation month in UTC, format `YYYYMM` |
| `--kinds` | `-k` | `vm sql storage webapp` | Resource kinds to process |
| `--resource` | `-r` | *(all)* | Filter to a single resource name |
| `--parallelism` | `-p` | *(auto)* | Max concurrent API calls (scales to CPU cores) |
| `--activity-grace-minutes` | `-g` | `10` | Post-operation grace window for Activity Log lifecycle events |
| `--batch` | `-b` | off | Use the regional Metrics Batch API instead of per-resource calls |
| `--batch-size` | | `10` | Max resources per batch call (1–50); implies `--batch` |
| `--workspace` | `-w` | *(none)* | Log Analytics workspace ID (GUID). Fetches Activity Log via bulk KQL; Resource Health uses hybrid approach (KQL for older + REST for last ~30 days) |
| `--version` | `-v` | | Print version and exit |

## Build

```bash
cd csharp/GetAvailability

# Debug (JIT, for development)
dotnet build

# Release Native AOT binary
dotnet publish -c Release -r win-x64   # output in bin/Release/net10.0/win-x64/publish/
```

## Examples

```bash
# Single subscription
./GetAvailability --subscriptions Contoso-Production --month 202603

# Multiple subscriptions, filtered by kind
./GetAvailability --subscriptions Contoso-Development Contoso-Production --month 202603 --kinds vm sql

# Single resource (SQL database by server/database name)
./GetAvailability --subscriptions Contoso-Development --month 202603 --resource sqlserver01/sqldb01

# Batch API with custom batch size
./GetAvailability --subscriptions Contoso-Production Contoso-Development --month 202603 --batch-size 20

# Use Log Analytics for Activity Log + Resource Health (faster, extended retention)
./GetAvailability --subscriptions Contoso-Production --month 202603 --workspace b233a4b7-3c43-433c-ac60-1f6ff217ddd4

# Run directly without publishing
cd csharp/GetAvailability
dotnet run -- --subscriptions Contoso-Production --month 202603
```

## Implementation Notes

- **`Parallel.ForEachAsync`** for concurrent metric, Activity Log, and Resource Health queries with configurable parallelism.
- **`System.Text.Json`** for AOT-safe, efficient JSON parsing.
- **Native AOT** — ~15 MB standalone binary, no .NET runtime required.
- **O(1) JSON property access** — `TryGetProperty` hash lookup instead of `EnumerateObject` linear scan (~44k calls per resource per month).
- **Ticks-based metric keying** — `long` instead of `DateTime` for zero-allocation per data point.
- **HashSet-based interval containment** — suspect-minute classification pre-expands intervals into `HashSet<long>` tick sets for O(1) lookups instead of linear scans.

> **Note:** The C# version does not currently support the Log Analytics ingestion feature (`-DceEndpoint`/`-DcrImmutableId`). Use the PowerShell version for that capability.

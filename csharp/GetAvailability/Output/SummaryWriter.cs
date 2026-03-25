using GetAvailability.Models;

namespace GetAvailability.Output;

/// <summary>Writes the per-resource table and per-subscription/overall availability summaries.</summary>
public static class SummaryWriter
{
    /// <summary>Prints a fixed-width table with one row per resource showing availability metrics.</summary>
    public static void WriteResults(EligibilityResult[] sorted)
    {
        // Table header — compact column widths to fit standard terminals.
        // Columns: Subscription(24) Name(30) Kind(7) Location(12) Suspect(7) Faults(6)
        //          Excused(7) Unresolved(10) AvailMin(10) EligMin(8) Avail%(10)
        const string fmt = "{0,-24} {1,-30} {2,-7} {3,-12} {4,7} {5,6} {6,7} {7,10} {8,10} {9,8} {10,10}";
        Console.WriteLine();
        Console.WriteLine(string.Format(fmt,
            "Subscription", "Name", "Kind", "Location",
            "Suspect", "Faults", "Excused", "Unresolved",
            "AvailMin", "EligMin", "Avail%"));
        Console.WriteLine(new string('─', 141));

        foreach (var r in sorted)
        {
            Console.WriteLine(string.Format(fmt,
                Truncate(r.SubscriptionName, 24),
                Truncate(r.Name, 30),
                ShortKind(r.Kind),
                r.Location,
                r.SuspectMinutes > 0 ? $"{r.SuspectMinutes}" : "",
                r.ConfirmedDowntimeMinutes > 0 ? $"{r.ConfirmedDowntimeMinutes}" : "",
                r.ExcusedMinutes > 0 ? $"{r.ExcusedMinutes}" : "",
                r.UnexplainedSuspectMinutes > 0 ? $"{r.UnexplainedSuspectMinutes}" : "",
                Math.Round(r.AvailableMinutes, 2),
                r.EligibleMinutes,
                r.AvailabilityPct));
        }
        Console.WriteLine();
    }

    /// <summary>
    /// Prints per-subscription summaries (grouped by Kind + Location with resource count and
    /// aggregate availability %) followed by a cross-subscription overall summary when
    /// multiple subscriptions are present.
    /// </summary>
    public static void WriteSubscriptionSummaries(EligibilityResult[] sorted)
    {
        var eligible = sorted.Where(r => r.AvailabilityPct != "N/A").ToArray();

        foreach (var subGroup in eligible.GroupBy(r => r.SubscriptionName).OrderBy(g => g.Key))
        {
            Console.WriteLine($"--- {subGroup.Key} Summary ---");
            foreach (var g in subGroup.GroupBy(r => (r.Kind, r.Location)).OrderBy(g => g.Key))
            {
                int n = g.Count();
                double a = g.Sum(r => r.AvailableMinutes);
                double e = g.Sum(r => r.EligibleMinutes);
                double pct = e > 0 ? Math.Round(a / e * 100, 5) : 0;
                Console.WriteLine($"  {ShortKind(g.Key.Kind)}, {g.Key.Location} [{n} res]: {pct}% ({Math.Round(a, 2)} / {Math.Round(e, 2)} eligible min)");
            }
            int tn = subGroup.Count();
            double ta = subGroup.Sum(r => r.AvailableMinutes);
            double te = subGroup.Sum(r => r.EligibleMinutes);
            double tpct = te > 0 ? Math.Round(ta / te * 100, 5) : 0;
            Console.WriteLine($"  TOTAL [{tn} res]: {tpct}% ({Math.Round(ta, 2)} / {Math.Round(te, 2)} eligible min)");
            Console.WriteLine();
        }

        // Cross-subscription summary
        var subs = eligible.Select(r => r.SubscriptionName).Distinct().ToArray();
        if (subs.Length > 1 && eligible.Length > 0)
        {
            Console.WriteLine("══════════════════════════════════════════════════════════════");
            Console.WriteLine("               OVERALL (all subscriptions)");
            Console.WriteLine("══════════════════════════════════════════════════════════════");
            foreach (var g in eligible.GroupBy(r => (r.Kind, r.Location)).OrderBy(g => g.Key))
            {
                int n = g.Count();
                double a = g.Sum(r => r.AvailableMinutes);
                double e = g.Sum(r => r.EligibleMinutes);
                double pct = e > 0 ? Math.Round(a / e * 100, 5) : 0;
                Console.WriteLine($"  {ShortKind(g.Key.Kind)}, {g.Key.Location} [{n} res]: {pct}% ({Math.Round(a, 2)} / {Math.Round(e, 2)} eligible min)");
            }
            int on = eligible.Length;
            double oa = eligible.Sum(r => r.AvailableMinutes);
            double oe = eligible.Sum(r => r.EligibleMinutes);
            double opct = oe > 0 ? Math.Round(oa / oe * 100, 5) : 0;
            Console.WriteLine($"  OVERALL [{on} res]: {opct}% ({Math.Round(oa, 2)} / {Math.Round(oe, 2)} eligible min)");
            Console.WriteLine();
        }
    }

    /// <summary>Truncates a string to max length with "..." suffix, using Span to avoid allocation.</summary>
    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : string.Concat(s.AsSpan(0, max - 3), "...");

    /// <summary>Abbreviates resource kind for compact table display.</summary>
    private static string ShortKind(string kind) => kind switch
    {
        "VirtualMachine" => "VM",
        "AzureSqlDatabase" => "SQL",
        "StorageAccount" => "Storage",
        _ => kind
    };
}

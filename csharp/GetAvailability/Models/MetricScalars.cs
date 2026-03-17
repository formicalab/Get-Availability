namespace GetAvailability.Models;

public readonly record struct MetricScalars(double AvailableSum, int Recovered, int ZeroTxMin);

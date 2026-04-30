using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntelligenceAggregator.Functions;

public sealed class NewsAggregationFunction
{
    private readonly ILogger<NewsAggregationFunction> _logger;

    public NewsAggregationFunction(ILogger<NewsAggregationFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(RunNewsAggregation))]
    public Task RunNewsAggregation([TimerTrigger("%Aggregation__NewsSchedule%")] TimerInfo timerInfo, CancellationToken cancellationToken)
    {
        _logger.LogInformation("News aggregation started.");
        return Task.CompletedTask;
    }
}

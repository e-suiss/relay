namespace Esuiss.Relay;

public sealed partial class RelayApi
{
    private readonly RelayClient _client;

    internal RelayApi(RelayClient client) => _client = client;
}

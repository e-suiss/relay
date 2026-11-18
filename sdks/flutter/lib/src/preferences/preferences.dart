import '../core/http.dart';
import '../generated/models.dart';
import '../generated/operations.dart';

// X-31
// X-32
/// The subscriber's own notification preferences: preference switches and the delivery profile only; consents stay read-only in Access.
class RelayPreferencesApi {
  /// Creates the API.
  RelayPreferencesApi(this.http);

  /// The HTTP core.
  final RelayHttp http;

  /// Reads the preferences.
  Future<SubscriberPreferences> get() async {
    final RelayResponse r = await http.send(RelayOperation.getMyPreferences);
    return SubscriberPreferences.fromJson(r.json);
  }

  // X-44
  // PC-59
  /// Reads one page of the subscriber's consents from Relay's read-only copy; Relay never writes consent.
  Future<ConsentList> consents({int? limit, String? startingAfter}) async {
    final RelayResponse r = await http.send(
      RelayOperation.listMyConsents,
      query: <String, String?>{
        'limit': limit?.toString(),
        'starting_after': startingAfter,
      },
    );
    return ConsentList.fromJson(r.json);
  }

  // X-44
  /// Reads every page of the subscriber's consents, up to [maxPages] pages.
  Future<List<Consent>> allConsents({int maxPages = 10}) async {
    final List<Consent> all = <Consent>[];
    String? cursor;
    for (int page = 0; page < maxPages; page++) {
      final ConsentList list = await consents(
        limit: 100,
        startingAfter: cursor,
      );
      all.addAll(list.data);
      cursor = list.nextCursor;
      if (!list.hasMore || cursor == null) break;
    }
    return all;
  }

  /// Applies writes atomically.
  Future<SubscriberPreferences> update(MyPreferencesPatch patch) async {
    final RelayResponse r = await http.send(
      RelayOperation.updateMyPreferences,
      body: patch.toJson(),
    );
    return SubscriberPreferences.fromJson(r.json);
  }

  /// Sets one category and channel.
  Future<SubscriberPreferences> setCell(
    String category,
    Channel channel,
    PreferenceValue value,
  ) => update(
    MyPreferencesPatch(
      preferences: <PreferenceWrite>[
        PreferenceWrite(
          level: PreferenceLevel.categoryChannel,
          category: category,
          channel: channel,
          value: value,
        ),
      ],
    ),
  );

  /// Chooses instant or digest delivery for a category.
  Future<SubscriberPreferences> setDigest(
    SubscriberPreferences current,
    String category,
    String choice,
  ) => update(
    MyPreferencesPatch(
      profile: PreferenceProfileWrite(
        digest: <String, String>{...current.profile.digest, category: choice},
      ),
    ),
  );
}

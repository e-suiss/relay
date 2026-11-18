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

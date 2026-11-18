import '../core/http.dart';
import '../generated/models.dart';
import '../generated/operations.dart';

// AG-26
// AG-35
/// Responses of the subscriber to waitpoints it is a responder of; a response is collected and passed on, never an approval.
class RelayWaitpointsApi {
  /// Creates the API.
  RelayWaitpointsApi(this.http);

  /// The HTTP core.
  final RelayHttp http;

  /// Sends a response with the subject digest the item showed.
  Future<WaitpointResponseReceipt> respond(
    String waitpointId,
    Object? response, {
    required String subjectDigest,
  }) async {
    final RelayResponse r = await http.send(
      RelayOperation.respondToMyWaitpoint,
      pathParams: <String, String>{'waitpoint_id': waitpointId},
      body: WaitpointResponseRequest(
        response: response,
        subjectDigest: subjectDigest,
      ).toJson(),
    );
    return WaitpointResponseReceipt.fromJson(r.json);
  }
}

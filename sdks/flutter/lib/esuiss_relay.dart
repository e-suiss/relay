/// Flutter client for Relay: inbox, realtime, push devices, receipts and preferences, with native widgets.
library;

export 'src/client.dart';
export 'src/core/boundary.dart';
export 'src/core/errors.dart';
export 'src/core/http.dart'
    show
        RelayHttp,
        RelayResponse,
        SubscriberToken,
        SubscriberTokenProvider,
        parseRetryAfter;
export 'src/core/ports.dart';
export 'src/generated/models.dart';
export 'src/generated/operations.dart';
export 'src/inbox/offline_queue.dart';
export 'src/inbox/store.dart';
export 'src/inbox/sync.dart';
export 'src/inbox/undo.dart';
export 'src/inbox/waitpoints.dart';
export 'src/preferences/preferences.dart';
export 'src/presence/device_status.dart';
export 'src/push/adapter.dart';
export 'src/push/channels.dart';
export 'src/push/content.dart';
export 'src/push/devices.dart';
export 'src/push/handler.dart';
export 'src/push/payload.dart';
export 'src/push/receipts.dart';
export 'src/realtime/connection.dart';
export 'src/realtime/io_websocket.dart';
export 'src/realtime/phoenix.dart';
export 'src/realtime/poll.dart';
export 'src/realtime/sse.dart';
export 'src/realtime/transport.dart';
export 'src/ui/bell.dart';
export 'src/ui/inbox_list.dart';
export 'src/ui/l10n.dart';
export 'src/ui/preference_center.dart';
export 'src/ui/scope.dart';
export 'src/ui/theme.dart';

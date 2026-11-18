import { Linking } from "react-native";
import { myBackend, openInbox, storage } from "./backend";
// #region app
import {
  createRelayClient,
  InboxBell,
  InboxList,
  PreferenceCenter,
  RelayProvider,
} from "@esuiss/relay-react-native";

const relay = createRelayClient({
  baseUrl: "https://relay.example.com",
  storage,
  locale: "tr-TR",
  timezone: "Europe/Istanbul",
  tokenProvider: ({ forceRefresh }) => myBackend.relaySubscriberToken({ forceRefresh }),
});

export function App() {
  return (
    <RelayProvider client={relay} brand={{ primary: "#0B5FFF" }}>
      <InboxBell onPress={openInbox} />
      <InboxList onOpenItem={(item) => item.url && Linking.openURL(item.url)} />
      <PreferenceCenter />
    </RelayProvider>
  );
}
// #endregion app

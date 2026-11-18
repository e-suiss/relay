import { Linking } from 'react-native';

/** Opens a link with the app's handler when given, else with the system. */
export function openLink(url: string, onOpenUrl?: (url: string) => void): void {
  if (onOpenUrl) {
    onOpenUrl(url);
    return;
  }
  void Linking.openURL(url).catch(() => undefined);
}

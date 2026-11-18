package app.suiss.relay;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class Headers {
  private Headers() {}

  static List<String> all(Map<String, ? extends List<String>> headers, String name) {
    List<String> values = new ArrayList<>();
    if (headers == null) {
      return values;
    }
    String wanted = name.toLowerCase(Locale.ROOT);
    for (Map.Entry<String, ? extends List<String>> entry : headers.entrySet()) {
      if (entry.getKey() != null
          && entry.getKey().toLowerCase(Locale.ROOT).equals(wanted)
          && entry.getValue() != null) {
        values.addAll(entry.getValue());
      }
    }
    return values;
  }

  static String first(Map<String, ? extends List<String>> headers, String name) {
    List<String> values = all(headers, name);
    return values.isEmpty() ? null : values.get(0);
  }
}

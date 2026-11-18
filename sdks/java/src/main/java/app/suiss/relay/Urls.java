package app.suiss.relay;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class Urls {
  private static final Pattern PARAM = Pattern.compile("\\{[A-Za-z0-9_]+\\}");
  private static final char[] HEX = "0123456789ABCDEF".toCharArray();

  private Urls() {}

  static URI build(URI base, String template, List<String> values, Map<String, String> query) {
    StringBuilder path = new StringBuilder();
    Matcher matcher = PARAM.matcher(template);
    int index = 0;
    int last = 0;
    while (matcher.find()) {
      if (index >= values.size() || values.get(index) == null) {
        throw new IllegalArgumentException("missing path parameter " + matcher.group());
      }
      path.append(template, last, matcher.start()).append(encode(values.get(index++)));
      last = matcher.end();
    }
    path.append(template.substring(last));
    String root = base.toString();
    if (root.endsWith("/")) {
      root = root.substring(0, root.length() - 1);
    }
    StringBuilder out = new StringBuilder(root).append(path);
    char separator = '?';
    for (Map.Entry<String, String> entry : query.entrySet()) {
      out.append(separator)
          .append(encode(entry.getKey()))
          .append('=')
          .append(encode(entry.getValue()));
      separator = '&';
    }
    return URI.create(out.toString());
  }

  static String encode(String value) {
    StringBuilder out = new StringBuilder();
    for (byte b : value.getBytes(StandardCharsets.UTF_8)) {
      int c = b & 0xff;
      if ((c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c == '-'
          || c == '.'
          || c == '_'
          || c == '~') {
        out.append((char) c);
      } else {
        out.append('%').append(HEX[c >> 4]).append(HEX[c & 0x0f]);
      }
    }
    return out.toString();
  }
}
